import argparse
import json
import time
from collections import Counter
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import tensorflow as tf
from transformers import BertTokenizerFast


ROOT_DIR = Path(__file__).resolve().parents[3]

DATASET_PATH = (
    ROOT_DIR.parents[3]
    / "datasets"
    / "NQ"
    / "curated"
    / "nq_validation.parquet"
)

MODEL_PATH = (
    ROOT_DIR.parent
    / "Dependencies"
    / "Packageable"
    / "Models"
    / "bert"
    / "bert_base_uncased_dynamic.tflite"
)

MODEL_SOURCE_DIR = (
    ROOT_DIR.parent
    / "Dependencies"
    / "Packageable"
    / "Model-Sources"
    / "bert"
    / "google-bert-base-uncased"
)

RESULT_DIR = ROOT_DIR / "TestCode" / "TestRecords" / "Results" / "week3"

RESULT_PATH = RESULT_DIR / "nq_bert_validation.json"

MODEL_NAME = "google-bert/bert-base-uncased"

MAX_SEQUENCE_LENGTH = 512
CHUNK_OVERLAP_TOKENS = 32


class BertTfliteEmbedder:
    def __init__(self, model_path: Path):
        self.interpreter = tf.lite.Interpreter(
            model_path=str(model_path),
        )

        self.input_details = (
            self.interpreter.get_input_details()
        )

        self.output_details = (
            self.interpreter.get_output_details()
        )

        if len(self.input_details) != 3:
            raise RuntimeError(
                "BERT TFLite 模型输入数量不是 3。"
            )

        if len(self.output_details) != 1:
            raise RuntimeError(
                "BERT TFLite 模型输出数量不是 1。"
            )

        self.current_shape = None

    def _resize(
        self,
        batch_size: int,
        sequence_length: int,
    ):
        shape = (
            batch_size,
            sequence_length,
        )

        if self.current_shape == shape:
            return

        for detail in self.input_details:
            self.interpreter.resize_tensor_input(
                detail["index"],
                list(shape),
            )

        self.interpreter.allocate_tensors()

        self.input_details = (
            self.interpreter.get_input_details()
        )

        self.output_details = (
            self.interpreter.get_output_details()
        )

        self.current_shape = shape

    def embed_batch(
        self,
        tokenizer: BertTokenizerFast,
        texts: list[str],
    ) -> np.ndarray:
        if not texts:
            return np.empty(
                (0, 768),
                dtype=np.float32,
            )

        encoded = tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=MAX_SEQUENCE_LENGTH,
            return_tensors="np",
        )

        input_ids = encoded[
            "input_ids"
        ].astype(np.int32)

        attention_mask = encoded[
            "attention_mask"
        ].astype(np.int32)

        token_type_ids = encoded.get(
            "token_type_ids"
        )

        if token_type_ids is None:
            token_type_ids = np.zeros_like(
                input_ids,
                dtype=np.int32,
            )
        else:
            token_type_ids = (
                token_type_ids.astype(
                    np.int32
                )
            )

        batch_size, sequence_length = (
            input_ids.shape
        )

        if sequence_length > MAX_SEQUENCE_LENGTH:
            raise RuntimeError(
                "BERT tokenizer 未遵守 512 token 上限。"
            )

        self._resize(
            batch_size,
            sequence_length,
        )

        values = {
            "input_ids": input_ids,
            "attention_mask": attention_mask,
            "token_type_ids": token_type_ids,
        }

        for detail in self.input_details:
            name = detail["name"]

            if "attention_mask" in name:
                value = values[
                    "attention_mask"
                ]
            elif "input_ids" in name:
                value = values[
                    "input_ids"
                ]
            elif "token_type_ids" in name:
                value = values[
                    "token_type_ids"
                ]
            else:
                raise RuntimeError(
                    "无法识别 BERT 输入 Tensor："
                    + name
                )

            self.interpreter.set_tensor(
                detail["index"],
                value,
            )

        self.interpreter.invoke()

        hidden = self.interpreter.get_tensor(
            self.output_details[0]["index"]
        )

        mask = attention_mask.astype(
            np.float32
        )[:, :, None]

        summed = (
            hidden * mask
        ).sum(axis=1)

        counts = mask.sum(axis=1)

        embeddings = summed / counts

        norms = np.linalg.norm(
            embeddings,
            axis=1,
            keepdims=True,
        )

        embeddings = embeddings / norms

        return embeddings.astype(
            np.float32
        )


def extract_candidate_text(
    row: dict,
    candidate_index: int,
) -> str:
    tokens = row[
        "document"
    ]["tokens"]["token"]

    is_html = row[
        "document"
    ]["tokens"]["is_html"]

    candidates = row[
        "long_answer_candidates"
    ]

    start = candidates[
        "start_token"
    ][candidate_index]

    end = candidates[
        "end_token"
    ][candidate_index]

    return " ".join(
        token
        for token, html in zip(
            tokens[start:end],
            is_html[start:end],
        )
        if not html
    ).strip()


def consensus_candidates(
    row: dict,
) -> list[int]:
    ids = [
        answer["candidate_index"]
        for answer in row[
            "annotations"
        ]["long_answer"]
        if answer["candidate_index"] != -1
    ]

    if not ids:
        return []

    counts = Counter(ids)

    best_count = max(
        counts.values()
    )

    if best_count < 2:
        return []

    return sorted(
        candidate_index
        for candidate_index, count
        in counts.items()
        if count == best_count
    )


def build_validation_data(
    limit_queries: int,
):
    parquet = pq.ParquetFile(
        DATASET_PATH
    )

    queries = []
    documents = []
    query_positive_documents = []

    for batch in parquet.iter_batches(
        columns=[
            "id",
            "question",
            "document.tokens",
            "long_answer_candidates",
            "annotations",
        ],
        batch_size=128,
    ):
        for row in batch.to_pylist():
            positive_candidates = (
                consensus_candidates(row)
            )

            if not positive_candidates:
                continue

            question = row[
                "question"
            ]["text"].strip()

            if not question:
                continue

            positive_document_ids = []

            for candidate_index in (
                positive_candidates
            ):
                text = extract_candidate_text(
                    row,
                    candidate_index,
                )

                if not text:
                    continue

                document_id = len(
                    documents
                )

                documents.append(
                    {
                        "document_id": (
                            document_id
                        ),
                        "nq_id": row["id"],
                        "candidate_index": (
                            candidate_index
                        ),
                        "text": text,
                    }
                )

                positive_document_ids.append(
                    document_id
                )

            if not positive_document_ids:
                continue

            queries.append(
                {
                    "query_id": len(
                        queries
                    ),
                    "nq_id": row["id"],
                    "text": question,
                }
            )

            query_positive_documents.append(
                positive_document_ids
            )

            if (
                limit_queries > 0
                and len(queries)
                >= limit_queries
            ):
                return (
                    queries,
                    documents,
                    query_positive_documents,
                )

    return (
        queries,
        documents,
        query_positive_documents,
    )


def split_document(
    tokenizer: BertTokenizerFast,
    text: str,
) -> list[str]:
    encoded = tokenizer(
        text,
        max_length=MAX_SEQUENCE_LENGTH,
        truncation=True,
        stride=CHUNK_OVERLAP_TOKENS,
        return_overflowing_tokens=True,
        add_special_tokens=True,
    )

    chunks = []

    for token_ids in encoded[
        "input_ids"
    ]:
        chunks.append(
            tokenizer.decode(
                token_ids,
                skip_special_tokens=True,
                clean_up_tokenization_spaces=True,
            ).strip()
        )

    return [
        text
        for text in chunks
        if text
    ]


def embed_variable_length_texts(
    *,
    tokenizer: BertTokenizerFast,
    embedder: BertTfliteEmbedder,
    texts: list[str],
    batch_size: int,
    label: str,
):
    token_lengths = [
        len(
            tokenizer.encode(
                text,
                add_special_tokens=True,
            )
        )
        for text in texts
    ]

    order = sorted(
        range(len(texts)),
        key=lambda index: token_lengths[
            index
        ],
    )

    result = np.empty(
        (
            len(texts),
            768,
        ),
        dtype=np.float32,
    )

    started = time.perf_counter()

    completed = 0

    for start in range(
        0,
        len(order),
        batch_size,
    ):
        indices = order[
            start:start + batch_size
        ]

        batch_texts = [
            texts[index]
            for index in indices
        ]

        batch_embeddings = (
            embedder.embed_batch(
                tokenizer,
                batch_texts,
            )
        )

        for local_index, original_index in enumerate(
            indices
        ):
            result[
                original_index
            ] = batch_embeddings[
                local_index
            ]

        completed += len(indices)

        if (
            completed == len(texts)
            or completed % 256 == 0
        ):
            elapsed = (
                time.perf_counter()
                - started
            )

            print(
                f"{label}: "
                f"{completed}/{len(texts)} "
                f"elapsed_s={elapsed:.1f}"
            )

    return result


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help=(
            "限制验证 query 数量。"
            "0 表示使用全部共识样本。"
        ),
    )

    parser.add_argument(
        "--batch-size",
        type=int,
        default=8,
        help="TFLite 推理 batch size。",
    )

    args = parser.parse_args()

    if args.limit < 0:
        raise ValueError(
            "--limit 不能小于 0。"
        )

    if args.batch_size <= 0:
        raise ValueError(
            "--batch-size 必须大于 0。"
        )

    print(
        "Loading BERT tokenizer..."
    )

    tokenizer = (
        BertTokenizerFast.from_pretrained(
            str(MODEL_SOURCE_DIR),
            local_files_only=True,
        )
    )

    print(
        "Building NQ consensus "
        "retrieval dataset..."
    )

    (
        queries,
        documents,
        query_positive_documents,
    ) = build_validation_data(
        args.limit
    )

    print(
        "queries =",
        len(queries),
    )

    print(
        "positive_documents =",
        len(documents),
    )

    print(
        "Splitting long documents..."
    )

    chunk_texts = []
    chunk_document_ids = []

    for document in documents:
        chunks = split_document(
            tokenizer,
            document["text"],
        )

        for chunk in chunks:
            chunk_texts.append(
                chunk
            )

            chunk_document_ids.append(
                document[
                    "document_id"
                ]
            )

    print(
        "document_chunks =",
        len(chunk_texts),
    )

    print(
        "Loading fully dynamic "
        "BERT TFLite model..."
    )

    embedder = BertTfliteEmbedder(
        MODEL_PATH
    )

    experiment_started = (
        time.perf_counter()
    )

    print(
        "Embedding document chunks..."
    )

    chunk_embeddings = (
        embed_variable_length_texts(
            tokenizer=tokenizer,
            embedder=embedder,
            texts=chunk_texts,
            batch_size=args.batch_size,
            label="documents",
        )
    )

    print(
        "Embedding queries..."
    )

    query_embeddings = (
        embed_variable_length_texts(
            tokenizer=tokenizer,
            embedder=embedder,
            texts=[
                query["text"]
                for query in queries
            ],
            batch_size=args.batch_size,
            label="queries",
        )
    )

    document_embeddings = np.empty(
        (
            len(documents),
            768,
        ),
        dtype=np.float32,
    )

    document_embeddings[:] = np.nan

    chunks_by_document = {}

    for chunk_index, document_id in enumerate(
        chunk_document_ids
    ):
        chunks_by_document.setdefault(
            document_id,
            [],
        ).append(
            chunk_index
        )

    for document_id, chunk_indices in (
        chunks_by_document.items()
    ):
        values = chunk_embeddings[
            chunk_indices
        ]

        mean_vector = values.mean(
            axis=0
        )

        norm = np.linalg.norm(
            mean_vector
        )

        document_embeddings[
            document_id
        ] = (
            mean_vector / norm
        )

    similarity_matrix = (
        query_embeddings
        @ document_embeddings.T
    )

    recall_1 = 0
    recall_5 = 0
    recall_10 = 0
    reciprocal_rank_sum = 0.0

    query_results = []

    for query_index in range(
        len(queries)
    ):
        scores = similarity_matrix[
            query_index
        ]

        ranking = np.argsort(
            -scores
        )

        positives = set(
            query_positive_documents[
                query_index
            ]
        )

        best_rank = None

        for rank, document_id in enumerate(
            ranking,
            start=1,
        ):
            if int(document_id) in positives:
                best_rank = rank
                break

        if best_rank is None:
            raise RuntimeError(
                "未找到 query 的正样本文档。"
            )

        if best_rank <= 1:
            recall_1 += 1

        if best_rank <= 5:
            recall_5 += 1

        if best_rank <= 10:
            recall_10 += 1

        reciprocal_rank_sum += (
            1.0 / best_rank
        )

        query_results.append(
            {
                "query_id": (
                    query_index
                ),
                "nq_id": queries[
                    query_index
                ]["nq_id"],
                "best_positive_rank": (
                    best_rank
                ),
                "positive_document_ids": (
                    sorted(positives)
                ),
            }
        )

    total = len(queries)

    elapsed = (
        time.perf_counter()
        - experiment_started
    )

    metrics = {
        "protocol": (
            "NQ consensus long-answer "
            "embedding retrieval"
        ),
        "model": MODEL_NAME,
        "tflite_model": (
            MODEL_PATH.name
        ),
        "max_sequence_length": (
            MAX_SEQUENCE_LENGTH
        ),
        "chunk_overlap_tokens": (
            CHUNK_OVERLAP_TOKENS
        ),
        "batch_size": args.batch_size,
        "queries": total,
        "documents": len(
            documents
        ),
        "document_chunks": len(
            chunk_texts
        ),
        "recall_at_1": (
            recall_1 / total
        ),
        "recall_at_5": (
            recall_5 / total
        ),
        "recall_at_10": (
            recall_10 / total
        ),
        "mrr": (
            reciprocal_rank_sum
            / total
        ),
        "elapsed_seconds": elapsed,
    }

    RESULT_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    RESULT_PATH.write_text(
        json.dumps(
            {
                "metrics": metrics,
                "queries": (
                    query_results
                ),
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    print()
    print(
        "NQ BERT VALIDATION COMPLETE"
    )

    print(
        "queries =",
        total,
    )

    print(
        "documents =",
        len(documents),
    )

    print(
        "document_chunks =",
        len(chunk_texts),
    )

    print(
        "Recall@1 =",
        f"{metrics['recall_at_1']:.4f}",
    )

    print(
        "Recall@5 =",
        f"{metrics['recall_at_5']:.4f}",
    )

    print(
        "Recall@10 =",
        f"{metrics['recall_at_10']:.4f}",
    )

    print(
        "MRR =",
        f"{metrics['mrr']:.4f}",
    )

    print(
        "elapsed_seconds =",
        round(
            elapsed,
            2,
        ),
    )

    print(
        "result_path =",
        RESULT_PATH,
    )


if __name__ == "__main__":
    main()
