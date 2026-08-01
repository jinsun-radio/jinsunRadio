"""SageMaker inference handler for faster-whisper Breeze-ASR-26 (CTranslate2).

介面刻意做成 OpenAI `/v1/audio/transcriptions` 相容：吃 multipart/form-data
（file / model / language / prompt / temperature / response_format），回 OpenAI
形狀的 {"text": ...}。前面那層代理因此只需要重新簽章、原封轉發，不用改寫 payload。

同時保留兩種原生用法：raw audio bytes（audio/*）與 {"audio_base64": ...} JSON。
"""

import base64
import ctypes
import glob
import io
import json
import logging
import os
import site
import time
from email.parser import BytesParser
from email.policy import default as email_default

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

# 照護領域詞彙預設值：壓同音字錯誤（實測「血壓要」→「血壓藥」）。
# 呼叫端傳 prompt / initial_prompt 時以呼叫端為準。
DEFAULT_PROMPT = os.environ.get(
    "ASR_INITIAL_PROMPT",
    "以下是長輩的居家照護語音：血壓藥、慢性病、回診、量血壓、送餐、跌倒、復健、輪椅。",
)


def _preload_cuda_libs():
    """CTranslate2 links against libcudnn/libcublas that ship inside the torch
    pip wheels rather than on the system loader path. Load them RTLD_GLOBAL
    before faster_whisper imports ctranslate2 so the soname lookups resolve."""
    roots = list(site.getsitepackages()) + ["/opt/conda/lib/python3.12/site-packages"]
    sonames = [
        "libcublas.so.12",
        "libcublasLt.so.12",
        "libcudnn.so.9",
        "libcudnn_graph.so.9",
        "libcudnn_engines_precompiled.so.9",
        "libcudnn_engines_runtime_compiled.so.9",
        "libcudnn_heuristic.so.9",
        "libcudnn_ops.so.9",
        "libcudnn_cnn.so.9",
        "libcudnn_adv.so.9",
    ]
    found = {}
    for root in roots:
        for path in glob.glob(os.path.join(root, "nvidia", "*", "lib", "*.so*")):
            found.setdefault(os.path.basename(path), path)
    for name in sonames:
        path = found.get(name)
        if not path:
            continue
        try:
            ctypes.CDLL(path, mode=ctypes.RTLD_GLOBAL)
        except OSError as exc:  # non-fatal: system copy may already satisfy it
            logger.warning("preload %s failed: %s", name, exc)


def _find_ct2_dir(model_dir):
    """The uncompressed S3 prefix keeps the CTranslate2 files under a nested
    dir, so locate whichever directory actually holds model.bin."""
    if os.path.isfile(os.path.join(model_dir, "model.bin")):
        return model_dir
    hits = glob.glob(os.path.join(model_dir, "**", "model.bin"), recursive=True)
    if not hits:
        raise FileNotFoundError(f"no model.bin found under {model_dir}")
    return os.path.dirname(hits[0])


def model_fn(model_dir, context=None):
    _preload_cuda_libs()
    from faster_whisper import WhisperModel

    ct2_dir = _find_ct2_dir(model_dir)
    device = os.environ.get("ASR_DEVICE", "cuda")
    compute_type = os.environ.get("ASR_COMPUTE_TYPE", "float16")
    logger.info("loading %s on %s (%s)", ct2_dir, device, compute_type)
    return WhisperModel(ct2_dir, device=device, compute_type=compute_type)


def _sniff_boundary(body):
    """multipart body 的第一行就是 --boundary。

    之所以要自己嗅：MMS 會攔截並解析 Content-Type 為 multipart/form-data 的請求，
    把 parts 拆散後 HF toolkit 只取名為 body 的那一份，於是 input_fn 收到 None。
    因此呼叫端要把 Content-Type 標成 application/octet-stream（body 原封不動），
    由這裡還原 boundary。見 examples/asr-proxy-route.mjs。
    """
    first = body[:200].split(b"\r\n", 1)[0].strip()
    if not first.startswith(b"--") or len(first) <= 2:
        return None
    return first[2:].decode("ascii", "replace")


def _parse_multipart(body, content_type):
    """OpenAI 的 /v1/audio/transcriptions 用 multipart。用標準庫的 email 解析器
    拆，省掉一個容器相依；韌體送的 boundary=Taiwan 也吃得下。"""
    if body is None:
        raise ValueError(
            "multipart body 沒有送達 handler：MMS 已先攔走。"
            "請改用 Content-Type: application/octet-stream 轉發原始 body。"
        )
    msg = BytesParser(policy=email_default).parsebytes(
        b"Content-Type: " + content_type.encode("utf-8") + b"\r\n\r\n" + body
    )
    if not msg.is_multipart():
        raise ValueError("malformed multipart/form-data body")

    audio, fields = None, {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name is None:
            continue
        payload = part.get_payload(decode=True) or b""
        if name == "file":
            audio = payload
        else:
            fields[name] = payload.decode("utf-8", "replace").strip()
    if audio is None:
        raise ValueError("multipart body has no 'file' part")
    return audio, fields


def _openai_options(fields):
    opts = {
        "language": fields.get("language") or "zh",
        # OpenAI 叫 prompt，faster-whisper 叫 initial_prompt。
        # 用「有沒有這個 key」判斷而非真假值：傳 prompt="" 是明確要求關掉預設詞彙
        # （想拿到可信的 segment 時間戳時會用到，見 README）。
        "initial_prompt": fields["prompt"] if "prompt" in fields else DEFAULT_PROMPT,
        "response_format": fields.get("response_format") or "json",
    }
    if fields.get("temperature"):
        opts["temperature"] = float(fields["temperature"])
    return opts


def input_fn(request_body, content_type="application/octet-stream", context=None):
    if isinstance(request_body, str):
        request_body = request_body.encode("utf-8")
    ctype = (content_type or "").split(";")[0].strip().lower()

    if ctype == "multipart/form-data":
        audio, f = _parse_multipart(request_body, content_type)
        return {"audio": io.BytesIO(audio), "options": _openai_options(f)}

    # 標成 octet-stream 但內容其實是 multipart（見 _sniff_boundary 的說明）
    if request_body and request_body[:2] == b"--":
        boundary = _sniff_boundary(request_body)
        if boundary:
            audio, f = _parse_multipart(
                request_body, f'multipart/form-data; boundary="{boundary}"'
            )
            return {"audio": io.BytesIO(audio), "options": _openai_options(f)}

    if ctype == "application/json":
        payload = json.loads(request_body.decode("utf-8"))
        b64 = payload.pop("audio_base64", None)
        if b64 is None:
            raise ValueError("application/json payload requires 'audio_base64'")
        # 同上：只有完全沒提到 initial_prompt 才套預設值。
        payload.setdefault("initial_prompt", DEFAULT_PROMPT)
        return {"audio": io.BytesIO(base64.b64decode(b64)), "options": payload}

    # raw audio bytes（audio/wav、audio/mpeg、application/octet-stream…）
    return {"audio": io.BytesIO(request_body), "options": {"initial_prompt": DEFAULT_PROMPT}}


def predict_fn(data, model, context=None):
    opts = data["options"]
    t0 = time.perf_counter()
    # Breeze-ASR-26 emits Mandarin orthography; pin the language per the model card.
    segments, info = model.transcribe(
        data["audio"],
        language=opts.get("language", "zh"),
        beam_size=int(opts.get("beam_size", 5)),
        vad_filter=bool(opts.get("vad_filter", True)),
        # 空字串要收斂成 None：faster-whisper 對兩者行為不同，傳 "" 仍會走
        # prompt 條件化路徑、把 segment 時間戳壓壞，等於關不掉。
        initial_prompt=opts.get("initial_prompt") or None,
        temperature=opts.get("temperature", 0.0),
        condition_on_previous_text=bool(opts.get("condition_on_previous_text", False)),
    )
    out = [
        {"id": i, "start": round(s.start, 3), "end": round(s.end, 3), "text": s.text}
        for i, s in enumerate(segments)
    ]
    return {
        "response_format": opts.get("response_format", "json"),
        "text": "".join(s["text"] for s in out).strip(),
        "segments": out,
        "language": info.language,
        "language_probability": round(info.language_probability, 4),
        "duration": round(info.duration, 3),
        "processing_ms": round((time.perf_counter() - t0) * 1000),
    }


def output_fn(prediction, accept="application/json", context=None):
    # 只回編碼後的 body —— 回傳 (body, type) tuple 會讓 toolkit 送出 JSON array
    # 而不是物件本身。
    fmt = prediction.pop("response_format", "json")
    if fmt == "text":
        return prediction["text"]
    if fmt == "verbose_json":
        # OpenAI verbose_json 的欄位名；processing_ms 是我們的擴充，無害。
        return json.dumps(
            {
                "task": "transcribe",
                "language": prediction["language"],
                "duration": prediction["duration"],
                "text": prediction["text"],
                "segments": prediction["segments"],
                "processing_ms": prediction["processing_ms"],
            },
            ensure_ascii=False,
        )
    # 預設 json：OpenAI 只保證有 text，其餘為擴充欄位。
    return json.dumps(prediction, ensure_ascii=False)
