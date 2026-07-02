# ai-inference

## Testing

### 1. Raw vLLM (direct, bypasses LiteLLM)

Qwen3-30B (`vllm` service, port 8907):
```bash
curl http://localhost:8907/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen_Qwen3-Coder-30B-A3B-Instruct",
    "messages": [{"role": "user", "content": "ping"}]
  }'
```

Nemotron-3 Super 120B (`vllm-nemotron` service, port 8908):
```bash
curl http://localhost:8908/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4",
    "messages": [{"role": "user", "content": "ping"}]
  }'
```

### 2. Through LiteLLM (gateway, port 9001)

Health check:
```bash
curl http://localhost:9001/health/liveliness
```

List models registered in `config.yaml`:
```bash
curl http://localhost:9001/v1/models \
  -H "Authorization: Bearer sk-admin-master-key-change-me"
```

Qwen3-30b via LiteLLM:
```bash
curl http://localhost:9001/v1/chat/completions \
  -H "Authorization: Bearer sk-admin-master-key-change-me" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-30b",
    "messages": [{"role": "user", "content": "ping"}]
  }'
```

Nemotron-3-super-120b via LiteLLM:
```bash
curl http://localhost:9001/v1/chat/completions \
  -H "Authorization: Bearer sk-admin-master-key-change-me" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nemotron-3-super-120b",
    "messages": [{"role": "user", "content": "ping"}]
  }'
```

Replace `sk-admin-master-key-change-me` with the value of `LITELLM_MASTER_KEY` if it's been overridden.
