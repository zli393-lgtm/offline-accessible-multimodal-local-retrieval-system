"""Loopback-only persistent vector-store adapter for the desktop application.

Run: python service.py --data-dir PATH --port 8765
The caller supplies embeddings; this service never downloads a model.
"""

import argparse
import json
import math
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import chromadb


def _literal_file_extension(hit):
    metadata = hit.get("metadata", {})
    stored = str(metadata.get("fileExtension", "")).strip().upper()
    if stored:
        return stored
    path = str(metadata.get("sourcePath", "")).replace("\\", "/")
    name = path.rsplit("/", 1)[-1].lower()
    if name.endswith(".fb2.zip"):
        return "FB2_ZIP"
    if "." in name and not name.startswith(".") and not name.endswith("."):
        return name.rsplit(".", 1)[-1].upper()
    legacy = str(metadata.get("fileType", "")).strip().upper()
    return "" if legacy == "UNKNOWN" else legacy


def validate_rows(space, file_object_id, rows, dimensions):
    expected = dimensions[space]
    identifiers = set()
    for row in rows:
        if len(row["embedding"]) != expected:
            raise ValueError(f"{space} embedding must have {expected} dimensions")
        metadata = row["metadata"]
        if metadata.get("fileObjectId") != file_object_id:
            raise ValueError("Vector row belongs to another file object")
        if metadata.get("space") != space:
            raise ValueError("Vector row uses the wrong vector space")
        if row["id"] in identifiers:
            raise ValueError("Vector record IDs must be unique")
        identifiers.add(row["id"])


def _delete_new_generation(collections, new_only_ids):
    last_error = None
    for attempt in range(3):
        try:
            for space, identifiers in new_only_ids.items():
                if identifiers:
                    collections[space].delete(ids=list(identifiers))
            return
        except Exception as error:  # pragma: no cover - exact backend errors vary
            last_error = error
            if attempt < 2:
                time.sleep(0.1 * (attempt + 1))
    raise RuntimeError(
        "New-generation cleanup failed after 3 attempts; partial vectors may remain"
    ) from last_error


def _validate_record_ids(record_ids):
    if not isinstance(record_ids, list) or any(
        not isinstance(identifier, str) or not identifier
        for identifier in record_ids
    ) or len(record_ids) != len(set(record_ids)):
        raise ValueError("record IDs must contain unique non-empty strings")


def stage_file_object_rows(pending_rows, dimensions, file_object_id, space, rows):
    if space not in dimensions:
        raise ValueError("Unknown vector space")
    validate_rows(space, file_object_id, rows, dimensions)
    staged = pending_rows.setdefault(
        file_object_id, {name: [] for name in dimensions}
    )
    existing_ids = {row["id"] for row in staged[space]}
    if any(row["id"] in existing_ids for row in rows):
        raise ValueError("A vector record ID was staged more than once")
    staged[space].extend(rows)
    return [row["id"] for row in rows]


def commit_file_object_rows(
    collections, dimensions, pending_rows, file_object_id, keep_ids_by_space
):
    staged = pending_rows.get(file_object_id)
    if staged is None:
        raise ValueError("No staged generation exists for this file object")
    for space, identifiers in keep_ids_by_space.items():
        _validate_record_ids(identifiers)
        staged_ids = [row["id"] for row in staged[space]]
        if identifiers != staged_ids:
            raise ValueError("Committed record IDs must exactly match staged rows")

    result = replace_file_object_rows(
        collections, dimensions, file_object_id, staged
    )
    pending_rows.pop(file_object_id, None)
    return result


def abort_file_object_rows(pending_rows, file_object_id, row_ids_by_space):
    for space, identifiers in row_ids_by_space.items():
        _validate_record_ids(identifiers)
    staged = pending_rows.pop(file_object_id, None)
    if staged is None:
        return 0
    return sum(len(rows) for rows in staged.values())


def replace_file_object_rows(collections, dimensions, file_object_id, rows_by_space):
    """Stage one version, then remove the previous version after all writes pass.

    Versioned row IDs keep the last complete file object searchable while the
    three modality collections are written.  If any upsert fails, only the new
    generation is removed and the previous generation is left untouched.
    """
    for space, rows in rows_by_space.items():
        validate_rows(space, file_object_id, rows, dimensions)

    old_ids = {
        space: set(
            collection.get(
                where={"fileObjectId": file_object_id}, include=[]
            ).get("ids", [])
        )
        for space, collection in collections.items()
    }
    new_ids = {
        space: {row["id"] for row in rows}
        for space, rows in rows_by_space.items()
    }
    new_only_ids = {
        space: new_ids[space] - old_ids[space] for space in collections
    }

    try:
        for space, rows in rows_by_space.items():
            if not rows:
                continue
            collections[space].upsert(
                ids=[row["id"] for row in rows],
                embeddings=[row["embedding"] for row in rows],
                documents=[row.get("document", "") for row in rows],
                metadatas=[row["metadata"] for row in rows],
            )
        # Lightweight read-back validation: no embeddings are read again.
        # Confirm only record count, IDs, file ownership and vector space.
        for space, identifiers in new_ids.items():
            if not identifiers:
                continue
            found = collections[space].get(
                ids=list(identifiers), include=["metadatas"]
            )
            if set(found.get("ids", [])) != identifiers or any(
                metadata.get("fileObjectId") != file_object_id
                or metadata.get("space") != space
                for metadata in found.get("metadatas", [])
            ):
                raise RuntimeError("New vector generation failed validation")
    except Exception:
        _delete_new_generation(collections, new_only_ids)
        raise

    # The complete new generation now exists.  Removing stale rows is the
    # commit step.  A cleanup error can leave duplicate generations, but it
    # cannot erase the only complete version of a file.
    for space, collection in collections.items():
        obsolete = old_ids[space] - new_ids[space]
        if obsolete:
            collection.delete(ids=list(obsolete))

    return {
        "textRecordIds": [row["id"] for row in rows_by_space["text"]],
        "imageRecordIds": [row["id"] for row in rows_by_space["image"]],
        "audioRecordIds": [row["id"] for row in rows_by_space["audio"]],
    }


def create_app(data_dir):
    client = chromadb.PersistentClient(path=str(data_dir))
    collections = {
        "text": client.get_or_create_collection(
            name="bert_text_chunks", metadata={"hnsw:space": "cosine"}
        ),
        "image": client.get_or_create_collection(
            name="mobileclip_images", metadata={"hnsw:space": "cosine"}
        ),
        "audio": client.get_or_create_collection(
            name="clap_audio", metadata={"hnsw:space": "cosine"}
        ),
    }
    dimensions = {"text": 768, "image": 512, "audio": 512}
    pending_rows = {}
    prepared_queries = {}
    prepared_queries_lock = threading.Lock()
    collection = collections["text"]

    file_locks = {}
    file_locks_guard = threading.Lock()

    def lock_for(file_object_id):
        with file_locks_guard:
            return file_locks.setdefault(file_object_id, threading.Lock())

    def hit_from_record(record_id, document, metadata, distance=None):
        return {
            "id": record_id,
            "document": document or "",
            "metadata": metadata,
            "distance": distance,
            "vectorMatched": distance is not None,
            "keywordMatched": False,
        }

    def better_hit(candidate, previous):
        candidate_score = candidate.get("relevanceScore")
        previous_score = previous.get("relevanceScore")
        if candidate_score is not None or previous_score is not None:
            left = float("-inf") if candidate_score is None else candidate_score
            right = float("-inf") if previous_score is None else previous_score
            if left != right:
                return left > right
        left_distance = candidate.get("distance")
        right_distance = previous.get("distance")
        left_distance = float("inf") if left_distance is None else left_distance
        right_distance = float("inf") if right_distance is None else right_distance
        if left_distance != right_distance:
            return left_distance < right_distance
        return candidate["id"] < previous["id"]

    def reply_query_page(token, page_index):
        with prepared_queries_lock:
            prepared = prepared_queries.get(token)
        if prepared is None:
            raise ValueError("Prepared query has expired")
        base_files = prepared["baseFiles"]
        refinement = prepared.get("refinement", {})
        filter_enabled = bool(refinement.get("fileTypeFilterEnabled", False))
        allowed_types = set(refinement.get("allowedFileTypes", []))
        known_types = set(refinement.get("knownFileTypes", []))
        include_other = bool(refinement.get("includeOtherFileTypes", False))
        def visible_files():
            files = []
            for hit in base_files:
                file_type = _literal_file_extension(hit)
                is_other = not file_type or file_type == "UNKNOWN" or file_type not in known_types
                if filter_enabled and file_type not in allowed_types and not (
                    include_other and is_other
                ):
                    continue
                files.append(hit)
            return files

        page_size = prepared["pageSize"]
        page_index = max(0, int(page_index))
        lazy_scan = prepared.get("lazyScanOne")
        # Read only far enough to fill the requested page plus one result. The
        # extra result tells the UI that a next page exists without exhausting
        # the complete index or claiming a final total too early.
        if lazy_scan is not None and refinement.get("sort", "indexOrder") == "indexOrder":
            target = (page_index + 1) * page_size + 1
            order = prepared["fileObjectOrder"]
            while len(visible_files()) < target and prepared["cursor"] < len(order):
                hit = lazy_scan(order[prepared["cursor"]])
                prepared["cursor"] += 1
                if hit is not None:
                    base_files.append(hit)
        files = visible_files()
        sort = refinement.get("sort", "indexOrder")
        if sort == "extension":
            files.sort(key=lambda hit: (
                _literal_file_extension(hit),
                str(hit.get("metadata", {}).get("sourcePath", "")).casefold(),
            ))
        elif sort == "fileName":
            files.sort(key=lambda hit: (
                str(hit.get("metadata", {}).get("sourcePath", "")).replace("\\", "/").rsplit("/", 1)[-1].casefold(),
                str(hit.get("metadata", {}).get("sourcePath", "")).casefold(),
            ))
        elif sort == "path":
            files.sort(key=lambda hit: str(
                hit.get("metadata", {}).get("sourcePath", "")
            ).casefold())
        elif sort == "relevance":
            files.sort(key=lambda hit: (
                -(hit.get("relevanceScore") if hit.get("relevanceScore") is not None else float("-inf")),
                hit.get("distance") if hit.get("distance") is not None else float("inf"),
                hit["id"],
            ))
        exhausted = lazy_scan is None or prepared["cursor"] >= len(prepared["fileObjectOrder"])
        has_more = len(files) > (page_index + 1) * page_size or not exhausted
        page_count = max(1, (len(files) + page_size - 1) // page_size)
        if exhausted:
            page_index = min(page_index, page_count - 1)
        start = page_index * page_size
        return {
            "queryToken": token,
            "totalFiles": len(files),
            "pageIndex": page_index,
            "pageSize": page_size,
            "files": files[start:start + page_size],
            "availableFileTypes": sorted({
                _literal_file_extension(hit)
                for hit in base_files
            }),
            "totalIsFinal": exhausted,
            "hasMore": has_more,
        }

    def refine_file_query(data):
        token = str(data["queryToken"])
        with prepared_queries_lock:
            prepared = prepared_queries.get(token)
            if prepared is None:
                raise ValueError("Prepared query has expired")
            sort = str(data.get("sort", "indexOrder"))
            if sort not in ("indexOrder", "relevance", "extension", "fileName", "path"):
                raise ValueError("Unknown result sort")
            prepared["refinement"] = {
                "fileTypeFilterEnabled": bool(data.get("fileTypeFilterEnabled", False)),
                "allowedFileTypes": {
                    str(value).strip().upper()
                    for value in data.get("allowedFileTypes", [])
                    if str(value).strip()
                },
                "includeOtherFileTypes": bool(data.get("includeOtherFileTypes", False)),
                "knownFileTypes": {
                    str(value).strip().upper()
                    for value in data.get("knownFileTypes", [])
                    if str(value).strip()
                },
                "sort": sort,
            }
            # Any explicit result rearrangement requires a complete candidate
            # set. Default index-order paging remains incremental.
            if sort != "indexOrder" and prepared.get("lazyScanOne") is not None:
                order = prepared["fileObjectOrder"]
                while prepared["cursor"] < len(order):
                    hit = prepared["lazyScanOne"](order[prepared["cursor"]])
                    prepared["cursor"] += 1
                    if hit is not None:
                        prepared["baseFiles"].append(hit)
        return reply_query_page(token, 0)

    def prepare_file_query(data):
        page_size = max(1, int(data.get("pageSize", 6)))
        normalized_type = str(data.get("fileType", "")).strip().upper()
        type_filter_enabled = bool(data.get("fileTypeFilterEnabled", False))
        allowed_types = {
            str(value).strip().upper()
            for value in data.get("allowedFileTypes", [])
            if str(value).strip()
        }
        known_types = {
            str(value).strip().upper()
            for value in data.get("knownFileTypes", [])
            if str(value).strip()
        }
        include_other_types = bool(data.get("includeOtherFileTypes", False))
        allowed = data.get("allowedFileObjectIds")
        allowed = None if allowed is None else set(allowed)
        include_native = bool(data.get("includeNativeText", True))
        include_extracted = bool(data.get("includeExtractedText", True))
        relevance_thresholds = data.get("relevanceThresholds")
        file_order = {
            str(file_id): index
            for index, file_id in enumerate(data.get("fileObjectOrder", []))
        }
        best_by_file = {}

        def accepted(hit, query=None):
            metadata = hit["metadata"]
            file_id = metadata.get("fileObjectId")
            if not file_id or (allowed is not None and file_id not in allowed):
                return False
            if normalized_type and str(metadata.get("fileType", "")).upper() != normalized_type:
                return False
            file_type = _literal_file_extension(hit)
            if type_filter_enabled:
                is_other = (
                    not file_type
                    or file_type == "UNKNOWN"
                    or file_type not in known_types
                )
                if file_type not in allowed_types and not (
                    include_other_types and is_other
                ):
                    return False
            if query is not None:
                allowed_records = set(query.get("allowedRecordKinds", []))
                allowed_information = set(query.get("allowedInformationKinds", []))
                if allowed_records and metadata.get("recordKind", "raw") not in allowed_records:
                    return False
                information_kind = metadata.get("queryInformationKind")
                if not information_kind:
                    space = metadata.get("space")
                    if space == "image":
                        information_kind = "image"
                    elif space == "audio":
                        information_kind = "audio"
                    else:
                        method = metadata.get("textExtractionMethod")
                        kind = metadata.get("textInformationKind")
                        extracted = (method in ("ocr", "speechRecognition", "other")
                                     or kind in ("ocr", "speechTranscript", "metadata"))
                        information_kind = "extractedText" if extracted else "nativeText"
                if allowed_information and information_kind not in allowed_information:
                    return False
                if relevance_thresholds is not None and hit.get("distance") is not None:
                    if information_kind == "extractedText":
                        threshold_key = "extractedText"
                    elif information_kind == "image" or metadata.get("space") == "image":
                        threshold_key = "image"
                    elif information_kind == "audio" or metadata.get("space") == "audio":
                        threshold_key = "audio"
                    else:
                        threshold_key = "nativeText"
                    threshold = relevance_thresholds.get(threshold_key)
                    if threshold is not None and (1.0 - float(hit["distance"])) < float(threshold):
                        return False
            if (metadata.get("space") == "text"
                    and metadata.get("recordKind", "raw") == "raw"
                    and metadata.get("queryInformationKind") != "fileName"):
                method = metadata.get("textExtractionMethod")
                kind = metadata.get("textInformationKind")
                extracted = method in ("ocr", "speechRecognition", "other") or kind in ("ocr", "speechTranscript")
                if extracted and not include_extracted:
                    return False
                if not extracted and not include_native:
                    return False
            return True

        def add(hit, query=None):
            if not accepted(hit, query):
                return
            file_id = hit["metadata"]["fileObjectId"]
            previous = best_by_file.get(file_id)
            if previous is None or better_hit(hit, previous):
                best_by_file[file_id] = hit

        supplied_by_file = {}
        for supplied in data.get("fileNameHits", []):
            candidate = dict(supplied)
            file_id = candidate.get("metadata", {}).get("fileObjectId")
            if file_id:
                supplied_by_file[file_id] = candidate

        def cosine_distance(left, right):
            dot = sum(float(a) * float(b) for a, b in zip(left, right))
            left_norm = math.sqrt(sum(float(value) ** 2 for value in left))
            right_norm = math.sqrt(sum(float(value) ** 2 for value in right))
            if left_norm == 0.0 or right_norm == 0.0:
                return 1.0
            return 1.0 - dot / (left_norm * right_norm)

        def scan_one_file(file_id):
            best = supplied_by_file.get(file_id)
            for query in data.get("vectors", []):
                space = str(query["space"])
                if space not in collections:
                    raise ValueError("Unknown vector space")
                embedding = query["embedding"]
                if len(embedding) != dimensions[space]:
                    raise ValueError(f"{space} query must have {dimensions[space]} dimensions")
                found = collections[space].get(
                    where={"fileObjectId": file_id},
                    include=["documents", "metadatas", "embeddings"],
                )
                embeddings = found.get("embeddings")
                if embeddings is None:
                    embeddings = []
                for record_id, document, metadata, candidate_embedding in zip(
                    found.get("ids", []), found.get("documents", []),
                    found.get("metadatas", []), embeddings,
                ):
                    distance = cosine_distance(embedding, candidate_embedding)
                    hit = hit_from_record(record_id, document, metadata, distance)
                    terms = [str(value).strip().casefold() for value in query.get("terms", []) if str(value).strip()]
                    hit["keywordMatched"] = any(term in str(document or "").casefold() for term in terms)
                    hit["relevanceScore"] = 1.0 - distance
                    if not accepted(hit, query):
                        continue
                    if best is None or better_hit(hit, best):
                        best = hit
            return best

        ordered_ids = list(file_order)
        if ordered_ids:
            token = uuid.uuid4().hex
            with prepared_queries_lock:
                if len(prepared_queries) >= 32:
                    oldest = next(iter(prepared_queries))
                    prepared_queries.pop(oldest, None)
                prepared_queries[token] = {
                    "baseFiles": [],
                    "pageSize": page_size,
                    "refinement": {"sort": "indexOrder"},
                    "fileObjectOrder": ordered_ids,
                    "cursor": 0,
                    "lazyScanOne": scan_one_file,
                }
            return reply_query_page(token, 0)

        for supplied in data.get("fileNameHits", []):
            add(dict(supplied))

        for query in data.get("vectors", []):
            space = str(query["space"])
            if space not in collections:
                raise ValueError("Unknown vector space")
            embedding = query["embedding"]
            if len(embedding) != dimensions[space]:
                raise ValueError(f"{space} query must have {dimensions[space]} dimensions")
            target = collections[space]
            available = target.count()
            if not available:
                continue
            result = target.query(
                query_embeddings=[embedding],
                n_results=available,
                include=["documents", "metadatas", "distances"],
            )
            vector_hits = [
                hit_from_record(record_id, document, metadata, distance)
                for record_id, document, metadata, distance in zip(
                    result["ids"][0], result["documents"][0],
                    result["metadatas"][0], result["distances"][0]
                )
            ]
            scores = {}
            by_id = {hit["id"]: hit for hit in vector_hits}
            vector_ids = set(by_id)
            keyword_ids = set()
            for rank, hit in enumerate(vector_hits):
                scores[hit["id"]] = scores.get(hit["id"], 0) + 1 / (61 + rank)
            if space == "text":
                seen = set()
                for term in query.get("terms", [])[:8]:
                    term = str(term).strip()
                    if not term:
                        continue
                    found = target.get(
                        where_document={"$contains": term},
                        limit=available,
                        include=["documents", "metadatas"],
                    )
                    channel = []
                    for record_id, document, metadata in zip(
                        found["ids"], found["documents"], found["metadatas"]
                    ):
                        if record_id in seen:
                            continue
                        seen.add(record_id)
                        hit = hit_from_record(record_id, document, metadata)
                        channel.append(hit)
                        by_id.setdefault(record_id, hit)
                    for rank, hit in enumerate(channel):
                        keyword_ids.add(hit["id"])
                        scores[hit["id"]] = scores.get(hit["id"], 0) + 1 / (61 + rank)
            for record_id, score in scores.items():
                hit = dict(by_id[record_id])
                hit["relevanceScore"] = score
                hit["vectorMatched"] = record_id in vector_ids
                hit["keywordMatched"] = record_id in keyword_ids
                add(hit, query)

        # Dict insertion order is the stable discovery order. Do not globally
        # sort by relevance unless the user explicitly requests that sort.
        files = list(best_by_file.values())
        if file_order:
            files.sort(key=lambda hit: file_order.get(
                str(hit.get("metadata", {}).get("fileObjectId", "")),
                len(file_order),
            ))
        token = uuid.uuid4().hex
        with prepared_queries_lock:
            # Query pages are short-lived application state. Bound retained
            # sessions so repeated searches cannot grow memory indefinitely.
            if len(prepared_queries) >= 32:
                oldest = next(iter(prepared_queries))
                prepared_queries.pop(oldest, None)
            prepared_queries[token] = {
                "baseFiles": files,
                "pageSize": page_size,
                "refinement": {"sort": "indexOrder"},
            }
        return reply_query_page(token, 0)

    class Handler(BaseHTTPRequestHandler):
        def _reply(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            size = int(self.headers.get("Content-Length", "0"))
            if size <= 0 or size > 64_000_000:
                raise ValueError("Invalid request size")
            return json.loads(self.rfile.read(size))

        def do_GET(self):
            if self.path == "/health":
                self._reply(
                    200,
                    {
                        "ok": True,
                        "count": collection.count(),
                        "counts": {
                            name: value.count() for name, value in collections.items()
                        },
                    },
                )
            else:
                self._reply(404, {"error": "Unknown endpoint"})

        def do_POST(self):
            try:
                data = self._body()
                if self.path == "/replace-file":
                    file_object_id = str(data["fileObjectId"]).strip()
                    if not file_object_id:
                        raise ValueError("fileObjectId must not be empty")
                    rows_by_space = {
                        "text": list(data.get("text", [])),
                        "image": list(data.get("image", [])),
                        "audio": list(data.get("audio", [])),
                    }
                    with lock_for(file_object_id):
                        result = replace_file_object_rows(
                            collections,
                            dimensions,
                            file_object_id,
                            rows_by_space,
                        )
                    return self._reply(200, result)
                if self.path == "/stage-file":
                    file_object_id = str(data["fileObjectId"]).strip()
                    if not file_object_id:
                        raise ValueError("fileObjectId must not be empty")
                    space = str(data["space"])
                    rows = list(data.get("rows", []))
                    with lock_for(file_object_id):
                        identifiers = stage_file_object_rows(
                            pending_rows,
                            dimensions,
                            file_object_id,
                            space,
                            rows,
                        )
                    return self._reply(200, {"stagedRecordIds": identifiers})
                if self.path == "/commit-file":
                    file_object_id = str(data["fileObjectId"]).strip()
                    if not file_object_id:
                        raise ValueError("fileObjectId must not be empty")
                    keep_ids_by_space = {
                        "text": list(data.get("textRecordIds", [])),
                        "image": list(data.get("imageRecordIds", [])),
                        "audio": list(data.get("audioRecordIds", [])),
                    }
                    with lock_for(file_object_id):
                        result = commit_file_object_rows(
                            collections,
                            dimensions,
                            pending_rows,
                            file_object_id,
                            keep_ids_by_space,
                        )
                    return self._reply(200, result)
                if self.path == "/abort-file":
                    file_object_id = str(data["fileObjectId"]).strip()
                    if not file_object_id:
                        raise ValueError("fileObjectId must not be empty")
                    row_ids_by_space = {
                        "text": list(data.get("textRecordIds", [])),
                        "image": list(data.get("imageRecordIds", [])),
                        "audio": list(data.get("audioRecordIds", [])),
                    }
                    with lock_for(file_object_id):
                        deleted = abort_file_object_rows(
                            pending_rows, file_object_id, row_ids_by_space
                        )
                    return self._reply(200, {"deleted": deleted})
                if self.path == "/remove-file":
                    file_object_id = str(data["fileObjectId"]).strip()
                    if not file_object_id:
                        raise ValueError("fileObjectId must not be empty")
                    with lock_for(file_object_id):
                        for target in collections.values():
                            target.delete(where={"fileObjectId": file_object_id})
                    return self._reply(200, {"removed": file_object_id})
                if self.path == "/prepare-file-query":
                    return self._reply(200, prepare_file_query(data))
                if self.path == "/file-query-page":
                    return self._reply(
                        200,
                        reply_query_page(
                            str(data["queryToken"]), int(data.get("pageIndex", 0))
                        ),
                    )
                if self.path == "/refine-file-query":
                    return self._reply(200, refine_file_query(data))
                if self.path == "/search-space":
                    space = str(data["space"])
                    if space not in collections:
                        raise ValueError("Unknown vector space")
                    vector = data["embedding"]
                    if len(vector) != dimensions[space]:
                        raise ValueError(
                            f"{space} query must have {dimensions[space]} dimensions"
                        )
                    # The application data layer may request the complete
                    # candidate set once to calculate an exact file-object
                    # count and cache stable pages.  Do not silently truncate
                    # that set to 100 vector records.
                    requested_limit = max(1, int(data.get("limit", 10)))
                    target = collections[space]
                    vector_hits = []
                    available = target.count()
                    limit = min(requested_limit, max(1, available))
                    if available:
                        result = target.query(
                            query_embeddings=[vector],
                            n_results=min(limit, available),
                            include=["documents", "metadatas", "distances"],
                        )
                        vector_hits = [
                            {
                                "id": record_id,
                                "document": document,
                                "metadata": metadata,
                                "distance": distance,
                            }
                            for record_id, document, metadata, distance in zip(
                                result["ids"][0],
                                result["documents"][0],
                                result["metadatas"][0],
                                result["distances"][0],
                            )
                        ]
                    keyword_hits = []
                    if space == "text":
                        terms = data.get("terms", [])
                        if not isinstance(terms, list) or any(
                            not isinstance(term, str) for term in terms
                        ):
                            raise ValueError("terms must be a list of strings")
                        seen = set()
                        for term in terms[:8]:
                            normalized = term.strip()
                            if not normalized:
                                continue
                            result = target.get(
                                where_document={"$contains": normalized},
                                limit=limit,
                                include=["documents", "metadatas"],
                            )
                            for record_id, document, metadata in zip(
                                result["ids"],
                                result["documents"],
                                result["metadatas"],
                            ):
                                if record_id in seen:
                                    continue
                                seen.add(record_id)
                                keyword_hits.append(
                                    {
                                        "id": record_id,
                                        "document": document,
                                        "metadata": metadata,
                                    }
                                )
                    return self._reply(
                        200,
                        {
                            # Keep results as a compatibility alias for older
                            # clients while exposing both ranking channels.
                            "results": vector_hits,
                            "vector": vector_hits,
                            "keyword": keyword_hits[:limit],
                        },
                    )
                if self.path == "/upsert":
                    rows = data["rows"]
                    if not rows:
                        return self._reply(200, {"upserted": 0})
                    for row in rows:
                        if len(row["embedding"]) != 768:
                            raise ValueError("BERT embedding must have 768 dimensions")
                    collection.upsert(
                        ids=[row["id"] for row in rows],
                        embeddings=[row["embedding"] for row in rows],
                        documents=[row["text"] for row in rows],
                        metadatas=[row["metadata"] for row in rows],
                    )
                    return self._reply(200, {"upserted": len(rows)})
                if self.path == "/search":
                    vector = data["embedding"]
                    if len(vector) != 768:
                        raise ValueError("BERT query must have 768 dimensions")
                    limit = max(1, min(int(data.get("limit", 10)), 100))
                    vector_hits = []
                    available = collection.count()
                    if available:
                        vector_result = collection.query(
                            query_embeddings=[vector],
                            n_results=min(limit, available),
                            include=["documents", "metadatas", "distances"],
                        )
                        vector_hits = [
                            {"id": record_id, "text": document, "metadata": metadata,
                             "distance": distance}
                            for record_id, document, metadata, distance in zip(
                                vector_result["ids"][0],
                                vector_result["documents"][0],
                                vector_result["metadatas"][0],
                                vector_result["distances"][0],
                            )
                        ]
                    keyword_hits = []
                    seen = set()
                    for term in data.get("terms", [])[:8]:
                        if not term.strip():
                            continue
                        result = collection.get(
                            where_document={"$contains": term},
                            limit=limit,
                            include=["documents", "metadatas"],
                        )
                        for record_id, document, metadata in zip(
                            result["ids"], result["documents"], result["metadatas"]
                        ):
                            if record_id not in seen:
                                seen.add(record_id)
                                keyword_hits.append({"id": record_id, "text": document,
                                                     "metadata": metadata})
                    return self._reply(200, {"vector": vector_hits,
                                             "keyword": keyword_hits[:limit]})
                self._reply(404, {"error": "Unknown endpoint"})
            except (KeyError, TypeError, ValueError) as error:
                self._reply(400, {"error": str(error)})
            except Exception as error:
                self._reply(500, {"error": str(error)})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), create_app(args.data_dir))
    print(f"Chroma service listening on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
