# ADR-002: Local LLM Design with llama.cpp

**Date:** 2026-03-10  
**Status:** Accepted  
**Author:** Wayne

## Context

The Tactical Console requires local LLM inference for:
- AI-generated git commit messages (`commit_auto`)
- Interactive chat (`burn`, `chat:`)
- Code explanation (`explain`)
- Model benchmarking (`model bench`)

Options considered:
1. **Cloud APIs** (OpenAI, Anthropic) - Latency, cost, privacy concerns
2. **Ollama** - Easy but less control over parameters
3. **llama.cpp** - Maximum control, GPU offload, pure C++ (no Python)

## Decision

Use **llama.cpp** with the following architecture:

### Components
```
llama-server    → HTTP API server (binds to 127.0.0.1:8081)
llama-cli       → CLI inference (not used - server preferred)
models.conf     → Registry of available models with metadata
active_llm      → State file tracking currently loaded model
```

### Key Design Choices

1. **Server mode over CLI** - Persistent server avoids model reload overhead
2. **Localhost-only binding** - Security (no external access)
3. **GGUF format** - Quantized models for 4GB VRAM constraint
4. **Pure bash integration** - No Python dependency in shell layer
5. **Streaming via curl + jq** - SSE stream parsing in pure bash

### GPU Offload Strategy
```bash
# -ngl 999 = offload maximum layers to GPU
# llama.cpp auto-determines what fits in VRAM
--n-gpu-layers 999 --flash-attn on

# CPU-only fallback for models > VRAM
--n-gpu-layers 0 --threads $(nproc)
```

### Model Registry Schema
```
num|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps
1|Phi-4-mini|phi-4-mini.Q4_K_M.gguf|2.5G|phi3|Q4_K_M|32|999|4096|8|45
```

## Consequences

### Positive
- **Privacy** - All inference runs locally, no data leaves machine
- **Cost** - No API fees, unlimited usage
- **Control** - Fine-tune parameters (ctx, threads, gpu_layers)
- **Speed** - 30-50 TPS on RTX 3050 Ti with quantized models
- **No Python** - Shell layer remains pure bash + curl + jq

### Negative
- **Setup complexity** - Users must build llama.cpp themselves
- **VRAM limits** - 4GB constrains model size to ~3B params at Q4
- **Manual updates** - Must rebuild llama.cpp for new features
- **Cold start** - 30-90s to load large models

### Trade-offs
- **llama.cpp vs Ollama** - Chose control over convenience
- **Server vs CLI** - Chose persistent state over simplicity
- **GGUF vs FP16** - Chose quantization for VRAM efficiency

## References
- Module: `scripts/11-llm-manager.sh`
- Watchdog: `bin/llama-watchdog.sh`
- Constants: `scripts/01-constants.sh` (LLM_PORT, LLAMA_ROOT)
