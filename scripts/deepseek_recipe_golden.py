"""Reference-renderer differential checks, not hosted API behavior.

Install: python -m pip install 'deepseek-recipe>=0.2,<0.3'
Run:     python3 scripts/deepseek_recipe_golden.py
"""
from deepseek_recipe import ChatCompletionRequest, ConversionOptions, DeepseekV41Encoding

MODEL = "DeepSeek-V4.1-Flash"
ENCODING = DeepseekV41Encoding()


def render(messages, *, tools=None, reasoning_effort="high", thinking=True):
    payload = {
        "model": MODEL,
        "messages": messages,
        "thinking": {"type": "enabled" if thinking else "disabled"},
    }
    if thinking:
        payload["reasoning_effort"] = reasoning_effort
    if tools is not None:
        payload["tools"] = tools
    conversation = ChatCompletionRequest(payload).convert(ConversionOptions()).conversation
    return ENCODING.render_conversation(conversation).prompt


def check():
    history = [
        {"role": "system", "content": "You are a coding assistant."},
        {"role": "user", "content": "Inspect this file."},
        {
            "role": "assistant",
            "content": "Proceeding.",
            "reasoning_content": "I should inspect the file first.",
        },
        {"role": "user", "content": "Summarize what you saw."},
    ]
    tools = [
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read source files",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            },
        }
    ]
    a = render(history, tools=tools)
    b = render(history, tools=None)
    assert "Read source files" in a
    assert "Read source files" not in b
    assert "I should inspect the file first." in a
    assert "I should inspect the file first." not in b
    # V4.1 levels collapse to three rendered prompt budgets; keep external
    # user effort strings distinct when sending the HTTP API request.
    low = render(history, reasoning_effort="low")
    medium = render(history, reasoning_effort="medium")
    high = render(history, reasoning_effort="high")
    ultra = render(history, reasoning_effort="max")
    assert "Reasoning Effort: 50" in low
    assert "Reasoning Effort: 75" in medium
    assert "Reasoning Effort: 75" in high
    assert "Reasoning Effort: 100" in ultra
    assert render(history, tools=tools) == render(history, tools=tools)
    print("DeepSeek V4.1 reference-renderer golden assertions passed")


if __name__ == "__main__":
    check()
