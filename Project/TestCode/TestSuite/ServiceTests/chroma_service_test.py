import importlib.util
import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SERVICE_PATH = ROOT / "ReleaseCode" / "services" / "chroma" / "service.py"


def _load_service():
    spec = importlib.util.spec_from_file_location("local_chroma_service", SERVICE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _request(base_url, method, path, body=None):
    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url}{path}",
        data=payload,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def _row(file_id, space, index, dimensions, value=0.0):
    return {
        "id": f"{file_id}:{space}:{index}",
        "document": f"document {index}" if space == "text" else "",
        "embedding": [value] * dimensions,
        "metadata": {
            "fileObjectId": file_id,
            "sourcePath": f"{file_id}.dat",
            "fileType": "TEST",
            "space": space,
        },
    }


def test_multimodal_replace_search_and_remove_are_file_object_scoped(tmp_path):
    service = _load_service()
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), service.create_app(tmp_path / "chroma")
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        status, health = _request(base, "GET", "/health")
        assert status == 200
        assert health["counts"] == {"text": 0, "image": 0, "audio": 0}

        first = {
            "fileObjectId": "file-a",
            "text": [
                _row("file-a", "text", 0, 768, 0.1),
                _row("file-a", "text", 1, 768, 0.2),
            ],
            "image": [_row("file-a", "image", 0, 512, 0.3)],
            "audio": [_row("file-a", "audio", 0, 512, 0.4)],
        }
        status, replaced = _request(base, "POST", "/replace-file", first)
        assert status == 200
        assert len(replaced["textRecordIds"]) == 2

        # Replacing a shorter version removes obsolete vectors for this file.
        first["text"] = [_row("file-a", "text", 0, 768, 0.1)]
        first["image"] = []
        status, _ = _request(base, "POST", "/replace-file", first)
        assert status == 200
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 1, "image": 0, "audio": 1}

        status, search = _request(
            base,
            "POST",
            "/search-space",
            {
                "space": "text",
                "embedding": [0.1] * 768,
                "terms": ["document"],
                "limit": 10,
            },
        )
        assert status == 200
        assert search["vector"][0]["metadata"]["fileObjectId"] == "file-a"
        assert search["keyword"][0]["metadata"]["fileObjectId"] == "file-a"
        assert search["results"] == search["vector"]

        # File-level query sessions expose the exact object count while only
        # returning the requested page to the application process.
        for index in range(1, 8):
            row = _row(f"file-{index}", "text", 0, 768, index / 10)
            status, _ = _request(
                base,
                "POST",
                "/replace-file",
                {
                    "fileObjectId": f"file-{index}",
                    "text": [row],
                    "image": [],
                    "audio": [],
                },
            )
            assert status == 200
        status, first_page = _request(
            base,
            "POST",
            "/prepare-file-query",
            {
                "vectors": [
                    {
                        "space": "text",
                        "embedding": [0.1] * 768,
                        "terms": ["document"],
                    }
                ],
                "fileNameHits": [],
                "pageSize": 3,
                "includeNativeText": True,
                "includeExtractedText": True,
            },
        )
        assert status == 200
        assert first_page["totalFiles"] == 8
        assert len(first_page["files"]) == 3
        status, last_page = _request(
            base,
            "POST",
            "/file-query-page",
            {"queryToken": first_page["queryToken"], "pageIndex": 2},
        )
        assert status == 200
        assert last_page["totalFiles"] == 8
        assert len(last_page["files"]) == 2

        # Default-order sessions scan only far enough to fill the requested
        # page plus one look-ahead result. They preserve registry/index order
        # and report an exact total only after the final page is reached.
        ordered_ids = [f"file-{index}" for index in range(7, 0, -1)] + ["file-a"]
        status, incremental = _request(
            base,
            "POST",
            "/prepare-file-query",
            {
                "vectors": [
                    {
                        "space": "text",
                        "embedding": [0.1] * 768,
                        "terms": ["document"],
                    }
                ],
                "fileNameHits": [],
                "fileObjectOrder": ordered_ids,
                "pageSize": 3,
                "includeNativeText": True,
                "includeExtractedText": True,
            },
        )
        assert status == 200
        assert incremental["totalIsFinal"] is False
        assert incremental["hasMore"] is True
        assert incremental["totalFiles"] == 4
        assert [item["metadata"]["fileObjectId"] for item in incremental["files"]] == ordered_ids[:3]
        status, incremental_last = _request(
            base,
            "POST",
            "/file-query-page",
            {"queryToken": incremental["queryToken"], "pageIndex": 2},
        )
        assert status == 200
        assert incremental_last["totalIsFinal"] is True
        assert incremental_last["hasMore"] is False
        assert incremental_last["totalFiles"] == 8
        assert [item["metadata"]["fileObjectId"] for item in incremental_last["files"]] == ordered_ids[6:]

        status, filtered = _request(
            base,
            "POST",
            "/refine-file-query",
            {
                "queryToken": first_page["queryToken"],
                "fileTypeFilterEnabled": True,
                "allowedFileTypes": [],
                "includeOtherFileTypes": False,
                "knownFileTypes": ["TXT"],
                "sort": "extension",
            },
        )
        assert status == 200
        assert filtered["totalFiles"] == 0
        # Suffix filtering is based on the literal path suffix, not the
        # parser's detected content-type label.
        assert filtered["availableFileTypes"] == ["DAT"]

        status, other = _request(
            base,
            "POST",
            "/refine-file-query",
            {
                "queryToken": first_page["queryToken"],
                "fileTypeFilterEnabled": True,
                "allowedFileTypes": [],
                "includeOtherFileTypes": True,
                "knownFileTypes": ["TXT"],
                "sort": "path",
            },
        )
        assert status == 200
        assert other["totalFiles"] == 8

        for result_sort in ("fileName", "relevance"):
            status, sorted_page = _request(
                base,
                "POST",
                "/refine-file-query",
                {
                    "queryToken": first_page["queryToken"],
                    "fileTypeFilterEnabled": False,
                    "sort": result_sort,
                },
            )
            assert status == 200
            assert sorted_page["totalFiles"] == 8

        status, removed = _request(
            base, "POST", "/remove-file", {"fileObjectId": "file-a"}
        )
        assert status == 200
        assert removed["removed"] == "file-a"
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 7, "image": 0, "audio": 0}
        for index in range(1, 8):
            _request(
                base,
                "POST",
                "/remove-file",
                {"fileObjectId": f"file-{index}"},
            )
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 0, "image": 0, "audio": 0}
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class _MemoryCollection:
    def __init__(self, rows=None, fail_upsert=False):
        self.rows = dict(rows or {})
        self.fail_upsert = fail_upsert

    def get(self, ids=None, where=None, include=None):
        file_id = None if where is None else where.get("fileObjectId")
        selected = [
            (identifier, row)
            for identifier, row in self.rows.items()
            if (ids is None or identifier in ids)
            and (file_id is None or row["metadata"]["fileObjectId"] == file_id)
        ]
        return {
            "ids": [identifier for identifier, _ in selected],
            "metadatas": [row["metadata"] for _, row in selected],
        }

    def upsert(self, ids, embeddings, documents, metadatas):
        if self.fail_upsert:
            raise RuntimeError("simulated modality write failure")
        for identifier, embedding, document, metadata in zip(
            ids, embeddings, documents, metadatas
        ):
            self.rows[identifier] = {
                "embedding": embedding,
                "document": document,
                "metadata": metadata,
            }

    def delete(self, ids):
        for identifier in ids:
            self.rows.pop(identifier, None)


def test_failed_multimodal_generation_is_cleaned_without_losing_previous_version():
    service = _load_service()
    dimensions = {"text": 2, "image": 2, "audio": 2}

    def row(identifier, space, version):
        return {
            "id": identifier,
            "document": f"version {version}",
            "embedding": [float(version), 0.0],
            "metadata": {
                "fileObjectId": "file-safe",
                "sourcePath": "safe.dat",
                "fileType": "TEST",
                "space": space,
                "objectVersion": version,
            },
        }

    old_text = row("file-safe:v1:text:0", "text", 1)
    old_image = row("file-safe:v1:image:0", "image", 1)
    collections = {
        "text": _MemoryCollection({old_text["id"]: old_text}),
        "image": _MemoryCollection(
            {old_image["id"]: old_image}, fail_upsert=True
        ),
        "audio": _MemoryCollection(),
    }
    new_text = row("file-safe:v2:text:0", "text", 2)
    new_image = row("file-safe:v2:image:0", "image", 2)

    try:
        service.replace_file_object_rows(
            collections,
            dimensions,
            "file-safe",
            {"text": [new_text], "image": [new_image], "audio": []},
        )
        raise AssertionError("the simulated image write must fail")
    except RuntimeError as error:
        assert "simulated modality write failure" in str(error)

    assert set(collections["text"].rows) == {old_text["id"]}
    assert set(collections["image"].rows) == {old_image["id"]}


def test_invalid_modality_is_rejected_before_any_collection_changes(tmp_path):
    service = _load_service()
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), service.create_app(tmp_path / "chroma")
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        body = {
            "fileObjectId": "file-b",
            "text": [_row("file-b", "text", 0, 768)],
            "image": [_row("file-b", "image", 0, 3)],
            "audio": [],
        }
        status, response = _request(base, "POST", "/replace-file", body)
        assert status == 400
        assert "512 dimensions" in response["error"]
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 0, "image": 0, "audio": 0}
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_batched_stage_commit_and_abort_keep_one_complete_generation(tmp_path):
    service = _load_service()
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), service.create_app(tmp_path / "chroma")
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        old = _row("file-stage", "text", 0, 768, 0.1)
        old["id"] = "file-stage:v1:text:0"
        status, _ = _request(
            base,
            "POST",
            "/replace-file",
            {"fileObjectId": "file-stage", "text": [old], "image": [], "audio": []},
        )
        assert status == 200

        new_text = _row("file-stage", "text", 0, 768, 0.2)
        new_text["id"] = "file-stage:v2:text:0"
        new_image = _row("file-stage", "image", 0, 512, 0.3)
        new_image["id"] = "file-stage:v2:image:0"
        for space, row in (("text", new_text), ("image", new_image)):
            status, staged = _request(
                base,
                "POST",
                "/stage-file",
                {"fileObjectId": "file-stage", "space": space, "rows": [row]},
            )
            assert status == 200
            assert staged["stagedRecordIds"] == [row["id"]]

        # Staged rows are not searchable and do not replace the old version.
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 1, "image": 0, "audio": 0}

        status, committed = _request(
            base,
            "POST",
            "/commit-file",
            {
                "fileObjectId": "file-stage",
                "textRecordIds": [new_text["id"]],
                "imageRecordIds": [new_image["id"]],
                "audioRecordIds": [],
            },
        )
        assert status == 200
        assert committed["textRecordIds"] == [new_text["id"]]
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 1, "image": 1, "audio": 0}

        abandoned = _row("file-stage", "text", 0, 768, 0.4)
        abandoned["id"] = "file-stage:v3:text:0"
        _request(
            base,
            "POST",
            "/stage-file",
            {"fileObjectId": "file-stage", "space": "text", "rows": [abandoned]},
        )
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 1, "image": 1, "audio": 0}
        status, aborted = _request(
            base,
            "POST",
            "/abort-file",
            {
                "fileObjectId": "file-stage",
                "textRecordIds": [abandoned["id"]],
                "imageRecordIds": [],
                "audioRecordIds": [],
            },
        )
        assert status == 200
        assert aborted["deleted"] == 1
        _, health = _request(base, "GET", "/health")
        assert health["counts"] == {"text": 1, "image": 1, "audio": 0}
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_legacy_text_endpoints_and_http_validation(tmp_path):
    service = _load_service()
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), service.create_app(tmp_path / "chroma")
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        status, empty = _request(base, "POST", "/upsert", {"rows": []})
        assert status == 200
        assert empty == {"upserted": 0}

        row = {
            "id": "legacy-text",
            "text": "searchable legacy document",
            "embedding": [0.25] * 768,
            "metadata": {
                "fileObjectId": "legacy-file",
                "sourcePath": "legacy.txt",
                "fileType": "TXT",
                "space": "text",
            },
        }
        status, inserted = _request(base, "POST", "/upsert", {"rows": [row]})
        assert status == 200
        assert inserted["upserted"] == 1

        status, found = _request(
            base,
            "POST",
            "/search",
            {
                "embedding": [0.25] * 768,
                "terms": ["", "searchable"],
                "limit": 500,
            },
        )
        assert status == 200
        assert found["vector"][0]["id"] == "legacy-text"
        assert found["keyword"][0]["id"] == "legacy-text"

        status, invalid = _request(
            base, "POST", "/search", {"embedding": [1.0], "terms": []}
        )
        assert status == 400
        assert "768 dimensions" in invalid["error"]
        status, invalid = _request(
            base,
            "POST",
            "/upsert",
            {"rows": [{**row, "embedding": [1.0]}]},
        )
        assert status == 400
        assert "768 dimensions" in invalid["error"]
        status, missing = _request(base, "POST", "/does-not-exist", {})
        assert status == 404
        assert missing["error"] == "Unknown endpoint"

        status, missing = _request(base, "GET", "/does-not-exist")
        assert status == 404
        assert missing["error"] == "Unknown endpoint"

        for endpoint in ("/replace-file", "/stage-file", "/commit-file",
                         "/abort-file", "/remove-file"):
            status, invalid = _request(
                base, "POST", endpoint, {"fileObjectId": ""}
            )
            assert status == 400
            assert "fileObjectId" in invalid["error"]

        for payload, message in [
            ({"space": "unknown", "embedding": []}, "Unknown vector space"),
            ({"space": "image", "embedding": [1.0]}, "512 dimensions"),
            ({"space": "text", "embedding": [0.0] * 768,
              "terms": "not-a-list"}, "list of strings"),
        ]:
            status, invalid = _request(base, "POST", "/search-space", payload)
            assert status == 400
            assert message in invalid["error"]

        status, invalid = _request(
            base, "POST", "/file-query-page",
            {"queryToken": "expired", "pageIndex": 0},
        )
        assert status == 400
        assert "expired" in invalid["error"]
        status, invalid = _request(
            base, "POST", "/refine-file-query",
            {"queryToken": "expired", "sort": "indexOrder"},
        )
        assert status == 400
        assert "expired" in invalid["error"]

        status, prepared = _request(
            base,
            "POST",
            "/prepare-file-query",
            {"vectors": [], "fileNameHits": [], "pageSize": 1},
        )
        assert status == 200
        status, invalid = _request(
            base, "POST", "/refine-file-query",
            {"queryToken": prepared["queryToken"], "sort": "random"},
        )
        assert status == 400
        assert "Unknown result sort" in invalid["error"]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_vector_generation_validation_and_abort_branches():
    service = _load_service()
    dimensions = {"text": 2, "image": 2, "audio": 2}
    pending = {}
    valid = {
        "id": "file:text:0",
        "embedding": [1.0, 0.0],
        "document": "x",
        "metadata": {
            "fileObjectId": "file",
            "sourcePath": "file.txt",
            "fileType": "TXT",
            "space": "text",
        },
    }

    for changed, message in [
        ({**valid, "embedding": [1.0]}, "dimensions"),
        ({**valid, "metadata": {**valid["metadata"], "fileObjectId": "other"}}, "another"),
        ({**valid, "metadata": {**valid["metadata"], "space": "image"}}, "wrong"),
    ]:
        try:
            service.validate_rows("text", "file", [changed], dimensions)
            raise AssertionError("invalid row accepted")
        except ValueError as error:
            assert message in str(error)
    try:
        service.validate_rows("text", "file", [valid, valid], dimensions)
        raise AssertionError("duplicate row accepted")
    except ValueError as error:
        assert "unique" in str(error)

    try:
        service.stage_file_object_rows(pending, dimensions, "file", "bad", [])
        raise AssertionError("unknown space accepted")
    except ValueError as error:
        assert "Unknown" in str(error)
    assert service.stage_file_object_rows(
        pending, dimensions, "file", "text", [valid]
    ) == [valid["id"]]
    try:
        service.stage_file_object_rows(pending, dimensions, "file", "text", [valid])
        raise AssertionError("duplicate staged row accepted")
    except ValueError as error:
        assert "more than once" in str(error)

    collections = {name: _MemoryCollection() for name in dimensions}
    try:
        service.commit_file_object_rows(
            collections,
            dimensions,
            {},
            "file",
            {name: [] for name in dimensions},
        )
        raise AssertionError("missing stage accepted")
    except ValueError as error:
        assert "No staged" in str(error)
    try:
        service.commit_file_object_rows(
            collections,
            dimensions,
            pending,
            "file",
            {"text": [], "image": [], "audio": []},
        )
        raise AssertionError("mismatched staged IDs accepted")
    except ValueError as error:
        assert "exactly match" in str(error)

    for invalid in [None, [""], ["x", "x"], [1]]:
        try:
            service._validate_record_ids(invalid)
            raise AssertionError("invalid record IDs accepted")
        except ValueError:
            pass
    assert service.abort_file_object_rows({}, "missing", {"text": []}) == 0
    assert service.abort_file_object_rows(
        pending, "file", {"text": [valid["id"]]}
    ) == 1

    assert service._literal_file_extension(
        {"metadata": {"fileExtension": "pdf"}}
    ) == "PDF"
    assert service._literal_file_extension(
        {"metadata": {"sourcePath": "book.fb2.zip"}}
    ) == "FB2_ZIP"
    assert service._literal_file_extension(
        {"metadata": {"sourcePath": "name.txt"}}
    ) == "TXT"
    assert service._literal_file_extension(
        {"metadata": {"sourcePath": ".hidden", "fileType": "UNKNOWN"}}
    ) == ""


def test_file_query_rejects_disallowed_modalities_types_and_thresholds(tmp_path):
    service = _load_service()
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), service.create_app(tmp_path / "chroma")
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        rows = {
            "native": _row("native", "text", 0, 768, 0.1),
            "extracted": _row("extracted", "text", 0, 768, 0.2),
            "image": _row("image", "image", 0, 512, 0.3),
            "audio": _row("audio", "audio", 0, 512, 0.4),
        }
        rows["native"]["metadata"].update(
            {"sourcePath": "native.txt", "fileType": "TXT", "recordKind": "raw"}
        )
        rows["extracted"]["metadata"].update(
            {"sourcePath": "scan.pdf", "fileType": "PDF", "recordKind": "raw",
             "textExtractionMethod": "ocr"}
        )
        rows["image"]["metadata"].update(
            {"sourcePath": "photo.png", "fileType": "PNG", "recordKind": "raw"}
        )
        rows["audio"]["metadata"].update(
            {"sourcePath": "sound.mp3", "fileType": "MP3", "recordKind": "raw"}
        )
        for file_id, row in rows.items():
            status, _ = _request(
                base, "POST", "/replace-file",
                {"fileObjectId": file_id,
                 "text": [row] if row["metadata"]["space"] == "text" else [],
                 "image": [row] if row["metadata"]["space"] == "image" else [],
                 "audio": [row] if row["metadata"]["space"] == "audio" else []},
            )
            assert status == 200

        query = lambda **extra: _request(
            base, "POST", "/prepare-file-query",
            {"vectors": extra.pop("vectors", [{"space": "text",
              "embedding": [0.1] * 768, "terms": []}]), "pageSize": 10, **extra},
        )
        assert query(allowedFileObjectIds=["missing"])[1]["totalFiles"] == 0
        assert query(fileType="PDF")[1]["totalFiles"] == 1
        assert query(fileTypeFilterEnabled=True, allowedFileTypes=["TXT"],
                     knownFileTypes=["TXT", "PDF"])[1]["totalFiles"] == 1
        assert query(includeNativeText=False,
                     allowedFileObjectIds=["native"])[1]["totalFiles"] == 0
        assert query(includeExtractedText=False, fileType="PDF")[1]["totalFiles"] == 0
        assert query(vectors=[{"space": "text", "embedding": [0.1] * 768,
                     "allowedRecordKinds": ["summary"], "terms": []}])[1]["totalFiles"] == 0
        assert query(vectors=[{"space": "text", "embedding": [0.1] * 768,
                     "allowedInformationKinds": ["image"], "terms": []}])[1]["totalFiles"] == 0
        assert query(vectors=[{"space": "text", "embedding": [0.1] * 768,
                     "relevanceThresholds": {"nativeText": 1.1}, "terms": []}],
                     relevanceThresholds={"nativeText": 1.1},
                     allowedFileObjectIds=["native"])[1]["totalFiles"] == 0
        supplied = dict(rows["native"])
        supplied.pop("embedding")
        supplied["relevanceScore"] = 2.0
        assert query(
            fileNameHits=[supplied],
            vectors=[
                {"space": "text", "embedding": [0.1] * 768, "terms": []},
                {"space": "text", "embedding": [0.2] * 768, "terms": []},
            ],
        )[1]["totalFiles"] == 2

        for vectors, expected in [
            ([{"space": "bad", "embedding": []}], "Unknown vector space"),
            ([{"space": "text", "embedding": [1.0]}], "768 dimensions"),
        ]:
            status, invalid = query(vectors=vectors)
            assert status == 400
            assert expected in invalid["error"]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
