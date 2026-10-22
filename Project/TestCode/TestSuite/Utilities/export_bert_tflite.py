import os
from pathlib import Path

os.environ["TF_CPP_MIN_LOG_LEVEL"] = "2"

import tensorflow as tf
from transformers import TFBertModel
from transformers.utils import logging

logging.set_verbosity_error()

MODEL_NAME = "google-bert/bert-base-uncased"

ROOT_DIR = Path(__file__).resolve().parents[3]
MODEL_SOURCE_DIR = (
    ROOT_DIR.parent
    / "Dependencies"
    / "Packageable"
    / "Model-Sources"
    / "bert"
    / "google-bert-base-uncased"
)
OUTPUT_DIR = ROOT_DIR.parent / "Dependencies" / "Packageable" / "Models" / "bert"

OUTPUT_MODEL = os.path.join(
    str(OUTPUT_DIR),
    "bert_base_uncased_dynamic.tflite",
)

MAX_SEQUENCE_LENGTH = 512


class BertTFLiteModule(tf.Module):
    def __init__(self, bert_model):
        super().__init__()
        self.bert_model = bert_model

    @tf.function(
        input_signature=[
            tf.TensorSpec(
                shape=[None, None],
                dtype=tf.int32,
                name="input_ids",
            ),
            tf.TensorSpec(
                shape=[None, None],
                dtype=tf.int32,
                name="attention_mask",
            ),
            tf.TensorSpec(
                shape=[None, None],
                dtype=tf.int32,
                name="token_type_ids",
            ),
        ]
    )
    def infer(
        self,
        input_ids,
        attention_mask,
        token_type_ids,
    ):
        outputs = self.bert_model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
            training=False,
        )

        return {
            "last_hidden_state": outputs.last_hidden_state,
        }


print("Loading BERT-base from local cache...")

bert = TFBertModel.from_pretrained(
    str(MODEL_SOURCE_DIR),
    local_files_only=True,
    from_pt=True,
)

bert.trainable = False

print("BERT model loaded.")
print("max_sequence_length =", MAX_SEQUENCE_LENGTH)
print("hidden_size =", bert.config.hidden_size)
print("batch_dimension = dynamic")
print("sequence_dimension = dynamic")

module = BertTFLiteModule(bert)

concrete_function = module.infer.get_concrete_function()

print("Creating TensorFlow Lite converter...")

converter = tf.lite.TFLiteConverter.from_concrete_functions(
    [concrete_function],
    module,
)

print("Starting TensorFlow Lite conversion...")

tflite_model = converter.convert()

os.makedirs(
    OUTPUT_DIR,
    exist_ok=True,
)

with open(OUTPUT_MODEL, "wb") as file:
    file.write(tflite_model)

model_size_mb = os.path.getsize(OUTPUT_MODEL) / (1024 * 1024)

print("BERT FULLY DYNAMIC TFLITE EXPORT OK")
print("input_shape = [dynamic, dynamic <= 512]")
print("output_shape = [dynamic, dynamic, 768]")
print("model_size_mb =", round(model_size_mb, 2))
print("model_path =", OUTPUT_MODEL)
