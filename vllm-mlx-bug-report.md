# Bug: `load_model_with_fallback` missing return statement — all models fail to load

## Repository

https://github.com/waybarrios/vllm-mlx

## Version

vllm-mlx 0.2.7 (pip metadata) / 0.2.5 (internal `__version__`)
mlx-lm 0.31.1
Python 3.14.3
macOS Darwin 25.4.0, Apple Silicon M5

## Description

`vllm-mlx serve` fails to start with **any** model. The error is:

```
TypeError: cannot unpack non-iterable NoneType object
```

in `engine/batched.py` line 257 (or `engine/simple.py` line 152):

```python
self._model, self._tokenizer = load_model_with_fallback(...)
```

## Root Cause

In `vllm_mlx/utils/tokenizer.py`, the function `load_model_with_fallback` is missing a `return` statement on the happy path.

```python
def load_model_with_fallback(model_name: str, tokenizer_config: dict = None):
    from mlx_lm import load

    tokenizer_config = tokenizer_config or {}

    if _needs_tokenizer_fallback(model_name):
        return _load_with_tokenizer_fallback(model_name)

    try:
        model, tokenizer = load(model_name, tokenizer_config=tokenizer_config)
        # BUG: no return here — function falls through and returns None
    except ValueError as e:
        if "TokenizersBackend" in str(e) or "Tokenizer class" in str(e):
            return _load_with_tokenizer_fallback(model_name)
        if "parameters not in model" in str(e):
            return _load_strict_false(model_name, tokenizer_config)
        raise
```

When `mlx_lm.load()` succeeds (no exception), the function completes the `try` block and falls off the end of the function, implicitly returning `None`. The `except` branches all have `return` statements, but the success path does not.

This means **every model that loads successfully will fail**, while only models that hit a specific `ValueError` fallback could possibly work (Nemotron, models with extra weights).

## Proof

```python
# mlx_lm.load works fine directly:
from mlx_lm import load
model, tokenizer = load('mlx-community/GLM-4.7-Flash-4bit')
# SUCCESS

# But vllm-mlx's wrapper returns None:
from vllm_mlx.utils.tokenizer import load_model_with_fallback
result = load_model_with_fallback('mlx-community/GLM-4.7-Flash-4bit')
# result is None
```

## Models tested (all fail)

- `mlx-community/GLM-4.7-Flash-4bit`
- `mlx-community/Qwen3.5-9B-MLX-4bit`
- `mlx-community/Qwen3.5-35B-A3B-4bit`

## Fix

Add `return model, tokenizer` after the successful `load()` call:

```diff
     try:
         model, tokenizer = load(model_name, tokenizer_config=tokenizer_config)
+        return model, tokenizer
     except ValueError as e:
```

## Full diff

```diff
--- a/vllm_mlx/utils/tokenizer.py
+++ b/vllm_mlx/utils/tokenizer.py
@@ -51,6 +51,7 @@ def load_model_with_fallback(model_name: str, tokenizer_config: dict = None):
 
     try:
         model, tokenizer = load(model_name, tokenizer_config=tokenizer_config)
+        return model, tokenizer
     except ValueError as e:
         # Fallback for models with non-standard tokenizers
         if "TokenizersBackend" in str(e) or "Tokenizer class" in str(e):
```

## Impact

This is a **critical** bug — it makes `vllm-mlx serve` completely non-functional for any model that doesn't require a tokenizer fallback. The server crashes on startup with every standard model.
