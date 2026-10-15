///|
/// Frozen real Magpie /v1/models response supplied for regression.
/// This fixture contains 78 entries and 12 routing groups.
fn real_catalog_body() -> String {
  (
    #|{"data":[{"context_length":922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z"
    #|,"display_name":"GPT-6-Luna","id":"group/auto-gpt-6-luna","magpie_label":"GPT-6-Luna · routing group","ma
    #|x_input_tokens":922000,"max_output_tokens":128000,"modalities":{"input":["text","image"]},"object":"model
    #|","owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},
    #|{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"type":"model"},{"context_length":922000,"context_
    #|window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GPT-5.6-Luna","id":"group/
    #|auto-gpt-5-6-luna","magpie_label":"GPT-5.6-Luna · routing group","max_input_tokens":922000,"max_output_to
    #|kens":128000,"modalities":{"input":["text","image"]},"object":"model","owned_by":"codex","reasoning":true
    #|,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},
    #|{"effort":"max"}],"type":"model"},{"context_length":1048576,"context_window":1048576,"created":0,"created
    #|_at":"2025-01-01T00:00:00Z","display_name":"Exo Free","id":"group/auto-exo-free","magpie_label":"Exo Free
    #| · routing group","max_input_tokens":1048576,"max_output_tokens":131072,"modalities":{"input":["text","im
    #|age"]},"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[],"typ
    #|e":"model"},{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00
    #|:00Z","display_name":"Muse Spark 1.3","id":"group/auto-muse-spark-1-3-contributor-free","magpie_label":"M
    #|use Spark 1.3 · routing group","max_input_tokens":1048576,"max_output_tokens":131072,"modalities":{"input
    #|":["text","image"]},"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_le
    #|vels":[],"type":"model"},{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"202
    #|5-01-01T00:00:00Z","display_name":"MiMo V2.6 Flash","id":"group/auto-mimo-v2-6-flash-free","magpie_label"
    #|:"MiMo V2.6 Flash · routing group","max_input_tokens":1048576,"max_output_tokens":131072,"modalities":{"i
    #|nput":["text","image"]},"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasonin
    #|g_levels":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":
    #|524288,"context_window":524288,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Space Bunn
    #|y","id":"group/auto-space-bunny-free","magpie_label":"Space Bunny · routing group","max_input_tokens":524
    #|288,"max_output_tokens":524288,"modalities":{"input":["text","image"]},"object":"model","owned_by":"our-f
    #|ree-model","reasoning":true,"supported_reasoning_levels":[],"type":"model"},{"context_length":1000000,"co
    #|ntext_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Longcat 2 5 Preview
    #| Free","id":"group/auto-longcat-2-5-preview-free","magpie_label":"Longcat 2 5 Preview Free · routing grou
    #|p","max_input_tokens":1000000,"max_output_tokens":131072,"modalities":{"input":["text","image"]},"object"
    #|:"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"light"},{"
    #|effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":1000000,"context_window":1000000
    #|,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Step 5 Preview Free","id":"group/auto-st
    #|ep-5-preview-free","magpie_label":"Step 5 Preview Free · routing group","max_input_tokens":1000000,"max_o
    #|utput_tokens":65536,"modalities":{"input":["text","image"]},"object":"model","owned_by":"our-free-model",
    #|"reasoning":true,"supported_reasoning_levels":[],"type":"model"},{"context_length":262144,"context_window
    #|":262144,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Ling 3.0 Flash Fin","id":"group/
    #|auto-ling-3-0-flash-fin-free","magpie_label":"Ling 3.0 Flash Fin · routing group","max_input_tokens":2621
    #|44,"max_output_tokens":32768,"modalities":{"input":["text"]},"object":"model","owned_by":"our-free-model"
    #|,"reasoning":true,"supported_reasoning_levels":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"
    #|}],"type":"model"},{"context_length":1000000,"context_window":1000000,"created":0,"created_at":"2025-01-0
    #|1T00:00:00Z","display_name":"Nemotron 3 Ultra","id":"group/auto-nemotron-3-ultra-free","magpie_label":"Ne
    #|motron 3 Ultra · routing group","max_input_tokens":1000000,"max_output_tokens":128000,"modalities":{"inpu
    #|t":["text"]},"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[
    #|{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":262144,"con
    #|text_window":262144,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Nemotron 3.5 Lightnin
    #|g","id":"group/auto-nemotron-3-5-lightning-free","magpie_label":"Nemotron 3.5 Lightning · routing group",
    #|"max_input_tokens":262144,"max_output_tokens":262144,"modalities":{"input":["text"]},"object":"model","ow
    #|ned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"light"},{"effort":"bal
    #|anced"},{"effort":"deep"}],"type":"model"},{"context_length":262144,"context_window":262144,"created":0,"
    #|created_at":"2025-01-01T00:00:00Z","display_name":"Ling 3 1 Flash Free","id":"group/auto-ling-3-1-flash-f
    #|ree","magpie_label":"Ling 3 1 Flash Free · routing group","max_input_tokens":262144,"max_output_tokens":3
    #|2768,"modalities":{"input":["text"]},"object":"model","owned_by":"our-free-model","reasoning":true,"suppo
    #|rted_reasoning_levels":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"con
    #|text_length":922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name
    #|":"GPT-6.1-Sol","id":"codex/gpt-6.1-sol","magpie_label":"GPT-6.1-Sol · Codex","max_input_tokens":922000,"
    #|max_output_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"o
    #|bject":"model","owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effor
    #|t":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"type":"model"},{"
    #|context_length":922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_n
    #|ame":"GPT-6-Astra","id":"codex/gpt-6-astra","magpie_label":"GPT-6-Astra · Codex","max_input_tokens":92200
    #|0,"max_output_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"]
    #|,"object":"model","owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"ef
    #|fort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"type":"model"}
    #|,{"context_length":922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","displa
    #|y_name":"GPT-6-Sol","id":"codex/gpt-6-sol","magpie_label":"GPT-6-Sol · Codex","max_input_tokens":922000,"
    #|max_output_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"o
    #|bject":"model","owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effor
    #|t":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"type":"model"},{"
    #|context_length":922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_n
    #|ame":"GPT-6-Luna","id":"codex/gpt-6-luna","magpie_label":"GPT-6-Luna · Codex","max_input_tokens":922000,"
    #|max_output_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"o
    #|bject":"model","owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effor
    #|t":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"type":"model"},{"context_length":922
    #|000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GPT-5.6-Sol",
    #|"id":"codex/gpt-5.6-sol","magpie_label":"GPT-5.6-Sol · Codex","max_input_tokens":922000,"max_output_token
    #|s":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"object":"model","
    #|owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"e
    #|ffort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"type":"model"},{"context_length":
    #|922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GPT-5.6-Te
    #|rra","id":"codex/gpt-5.6-terra","magpie_label":"GPT-5.6-Terra · Codex","max_input_tokens":922000,"max_out
    #|put_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"object":
    #|"model","owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"med
    #|ium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"type":"model"},{"context
    #|_length":922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"G
    #|PT-5.6-Luna","id":"codex/gpt-5.6-luna","magpie_label":"GPT-5.6-Luna · Codex","max_input_tokens":922000,"m
    #|ax_output_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"ob
    #|ject":"model","owned_by":"codex","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort
    #|":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"type":"model"},{"context_length":9220
    #|00,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GPT-5.6 Luna",
    #|"id":"copilot/gpt-5.6-luna","magpie_label":"GPT-5.6 Luna · Copilot","max_input_tokens":922000,"max_output
    #|_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"object":"mo
    #|del","owned_by":"copilot","reasoning":true,"supported_reasoning_levels":[{"effort":"none"},{"effort":"low
    #|"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"type":"model"},{"context_l
    #|ength":922000,"context_window":922000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GPT
    #|-6 Luna","id":"copilot/gpt-6-luna","magpie_label":"GPT-6 Luna · Copilot","max_input_tokens":922000,"max_o
    #|utput_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/responses"],"object
    #|":"model","owned_by":"copilot","reasoning":true,"supported_reasoning_levels":[{"effort":"none"},{"effort"
    #|:"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"type":"model"},{"crea
    #|ted":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Kimi K3 (GitHub)","id":"copilot/kimi-k3-base",
    #|"magpie_label":"Kimi K3 (GitHub) · Copilot","native_endpoints":["/v1/chat/completions"],"object":"model",
    #|"owned_by":"copilot","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"
    #|effort":"max"}],"type":"model"},{"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Kimi K3 
    #|(GitHub)","id":"copilot/kimi-k3-copilot","magpie_label":"Kimi K3 (GitHub) · Copilot","native_endpoints":[
    #|"/v1/chat/completions"],"object":"model","owned_by":"copilot","reasoning":true,"supported_reasoning_level
    #|s":[{"effort":"low"},{"effort":"high"},{"effort":"max"}],"type":"model"},{"context_length":1048576,"conte
    #|xt_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Kimi K3","id":"copilot
    #|/kimi-k3","magpie_label":"Kimi K3 · Copilot","max_input_tokens":1048576,"max_output_tokens":131072,"modal
    #|ities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by"
    #|:"copilot","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"m
    #|ax"}],"type":"model"},{"context_length":128000,"context_window":128000,"created":0,"created_at":"2025-01-
    #|01T00:00:00Z","display_name":"MAI-Code-1.1-Flash","id":"copilot/mai-code-1.1-flash","magpie_label":"MAI-C
    #|ode-1.1-Flash · Copilot","max_input_tokens":128000,"max_output_tokens":128000,"modalities":{"input":["tex
    #|t","image"]},"native_endpoints":["/v1/responses"],"object":"model","owned_by":"copilot","reasoning":true,
    #|"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"c
    #|ontext_length":272000,"context_window":272000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_na
    #|me":"GPT-5 mini","id":"copilot/gpt-5-mini","magpie_label":"GPT-5 mini · Copilot","max_input_tokens":27200
    #|0,"max_output_tokens":128000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/comple
    #|tions","/v1/responses"],"object":"model","owned_by":"copilot","reasoning":true,"supported_reasoning_level
    #|s":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":200000,"con
    #|text_window":200000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Claude Haiku 4.5","id
    #|":"copilot/claude-haiku-4.5","magpie_label":"Claude Haiku 4.5 · Copilot","max_input_tokens":200000,"max_o
    #|utput_tokens":64000,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completions","/
    #|v1/messages"],"object":"model","owned_by":"copilot","reasoning":true,"supported_reasoning_levels":[{"effo
    #|rt":"none"},{"effort":"high"}],"type":"model"},{"created":0,"created_at":"2025-01-01T00:00:00Z","display_
    #|name":"GPT-4.1","id":"copilot/gpt-4.1-2025-04-14","magpie_label":"GPT-4.1 · Copilot","native_endpoints":[
    #|"/v1/chat/completions","/v1/responses","/v1/messages"],"object":"model","owned_by":"copilot","reasoning":
    #|false,"supported_reasoning_levels":[],"type":"model"},{"context_length":1047576,"context_window":1047576,
    #|"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GPT-4.1","id":"copilot/gpt-4.1","magpie_l
    #|abel":"GPT-4.1 · Copilot","max_input_tokens":1047576,"max_output_tokens":32768,"modalities":{"input":["te
    #|xt","image"]},"native_endpoints":["/v1/chat/completions","/v1/responses","/v1/messages"],"object":"model"
    #|,"owned_by":"copilot","reasoning":false,"supported_reasoning_levels":[],"type":"model"},{"context_length"
    #|:1000000,"context_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GLM-5.3
    #|","id":"zcode/GLM-5.3","magpie_label":"GLM-5.3 · ZCode","max_input_tokens":1000000,"max_output_tokens":12
    #|8000,"modalities":{"input":["text"]},"native_endpoints":["/v1/messages"],"object":"model","owned_by":"zco
    #|de","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"max"}],"
    #|type":"model"},{"context_length":1000000,"context_window":1000000,"created":0,"created_at":"2025-01-01T00
    #|:00:00Z","display_name":"GLM-5.3-Flash","id":"zcode/GLM-5.3-Flash","magpie_label":"GLM-5.3-Flash · ZCode"
    #|,"max_input_tokens":1000000,"max_output_tokens":128000,"modalities":{"input":["text","image"]},"native_en
    #|dpoints":["/v1/messages"],"object":"model","owned_by":"zcode","reasoning":true,"supported_reasoning_level
    #|s":[{"effort":"low"},{"effort":"high"},{"effort":"max"}],"type":"model"},{"context_length":1000000,"conte
    #|xt_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"GLM-5.2","id":"zcode/G
    #|LM-5.2","magpie_label":"GLM-5.2 · ZCode","max_input_tokens":1000000,"max_output_tokens":128000,"modalitie
    #|s":{"input":["text"]},"native_endpoints":["/v1/messages"],"object":"model","owned_by":"zcode","reasoning"
    #|:true,"supported_reasoning_levels":[{"effort":"none"},{"effort":"high"},{"effort":"max"}],"type":"model"}
    #|,{"context_length":200000,"context_window":200000,"created":0,"created_at":"2025-01-01T00:00:00Z","displa
    #|y_name":"GLM-5-Turbo","id":"zcode/GLM-5-Turbo","magpie_label":"GLM-5-Turbo · ZCode","max_input_tokens":20
    #|0000,"max_output_tokens":64000,"modalities":{"input":["text"]},"native_endpoints":["/v1/messages"],"objec
    #|t":"model","owned_by":"zcode","reasoning":true,"supported_reasoning_levels":[{"effort":"none"},{"effort":
    #|"high"}],"type":"model"},{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"202
    #|5-01-01T00:00:00Z","display_name":"Gemini 3.1 Pro Preview","id":"gemini/gemini-3.1-pro-preview","magpie_l
    #|abel":"Gemini 3.1 Pro Preview · Gemini CLI","max_input_tokens":1048576,"max_output_tokens":65536,"modalit
    #|ies":{"input":["text","image"]},"object":"model","owned_by":"gemini","reasoning":true,"supported_reasonin
    #|g_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":1048
    #|576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Gemini 3 Pro
    #| Preview","id":"gemini/gemini-3-pro-preview","magpie_label":"Gemini 3 Pro Preview · Gemini CLI","max_inpu
    #|t_tokens":1048576,"max_output_tokens":65536,"modalities":{"input":["text","image"]},"object":"model","own
    #|ed_by":"gemini","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"type"
    #|:"model"},{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:0
    #|0Z","display_name":"Gemini 3 Flash Preview","id":"gemini/gemini-3-flash-preview","magpie_label":"Gemini 3
    #| Flash Preview · Gemini CLI","max_input_tokens":1048576,"max_output_tokens":65536,"modalities":{"input":[
    #|"text","image"]},"object":"model","owned_by":"gemini","reasoning":true,"supported_reasoning_levels":[{"ef
    #|fort":"minimal"},{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length
    #|":1048576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Gemini
    #| 3.8 Flash","id":"gemini/gemini-3.8-flash","magpie_label":"Gemini 3.8 Flash · Gemini CLI","max_input_toke
    #|ns":1048576,"max_output_tokens":65536,"modalities":{"input":["text","image"]},"object":"model","owned_by"
    #|:"gemini","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"
    #|high"}],"type":"model"},{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"2025
    #|-01-01T00:00:00Z","display_name":"Gemini 3.5 Flash","id":"gemini/gemini-3.5-flash","magpie_label":"Gemini
    #| 3.5 Flash · Gemini CLI","max_input_tokens":1048576,"max_output_tokens":65536,"modalities":{"input":["tex
    #|t","image"]},"object":"model","owned_by":"gemini","reasoning":true,"supported_reasoning_levels":[{"effort
    #|":"minimal"},{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":10
    #|48576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Gemini 3.5
    #| Flash Lite","id":"gemini/gemini-3.5-flash-lite","magpie_label":"Gemini 3.5 Flash Lite · Gemini CLI","max
    #|_input_tokens":1048576,"max_output_tokens":65536,"modalities":{"input":["text","image"]},"object":"model"
    #|,"owned_by":"gemini","reasoning":true,"supported_reasoning_levels":[{"effort":"minimal"},{"effort":"low"}
    #|,{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":1048576,"context_window":104857
    #|6,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Gemini 3.1 Flash Lite","id":"gemini/gem
    #|ini-3.1-flash-lite","magpie_label":"Gemini 3.1 Flash Lite · Gemini CLI","max_input_tokens":1048576,"max_o
    #|utput_tokens":65536,"modalities":{"input":["text","image"]},"object":"model","owned_by":"gemini","reasoni
    #|ng":true,"supported_reasoning_levels":[{"effort":"minimal"},{"effort":"low"},{"effort":"medium"},{"effort
    #|":"high"}],"type":"model"},{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"2
    #|025-01-01T00:00:00Z","display_name":"Gemini 2.5 Pro","id":"gemini/gemini-2.5-pro","magpie_label":"Gemini 
    #|2.5 Pro · Gemini CLI","max_input_tokens":1048576,"max_output_tokens":65536,"modalities":{"input":["text",
    #|"image"]},"object":"model","owned_by":"gemini","reasoning":true,"supported_reasoning_levels":[{"effort":"
    #|low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":1048576,"context_window":1
    #|048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Gemini 2.5 Flash","id":"gemini/gem
    #|ini-2.5-flash","magpie_label":"Gemini 2.5 Flash · Gemini CLI","max_input_tokens":1048576,"max_output_toke
    #|ns":65536,"modalities":{"input":["text","image"]},"object":"model","owned_by":"gemini","reasoning":true,"
    #|supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"co
    #|ntext_length":1048576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_n
    #|ame":"Gemini 2.5 Flash Lite","id":"gemini/gemini-2.5-flash-lite","magpie_label":"Gemini 2.5 Flash Lite · 
    #|Gemini CLI","max_input_tokens":1048576,"max_output_tokens":65536,"modalities":{"input":["text","image"]},
    #|"object":"model","owned_by":"gemini","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"ef
    #|fort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":32768,"context_window":32768,"create
    #|d":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Jev 1.13","id":"our-free-model/jev-1.13-free","m
    #|agpie_label":"Jev 1.13 · Our Free Model","max_input_tokens":32768,"max_output_tokens":4096,"modalities":{
    #|"input":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model
    #|","reasoning":false,"supported_reasoning_levels":[],"type":"model"},{"context_length":131072,"context_win
    #|dow":131072,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Exo Free","id":"our-free-mode
    #|l/exo-free","magpie_label":"Exo Free · Our Free Model","max_input_tokens":131072,"max_output_tokens":3276
    #|8,"modalities":{"input":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by"
    #|:"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"light"},{"effort":"balanced"}
    #|,{"effort":"deep"}],"type":"model"},{"context_length":1048576,"context_window":1048576,"created":0,"creat
    #|ed_at":"2025-01-01T00:00:00Z","display_name":"Muse Spark 1.3","id":"our-free-model/muse-spark-1.3-contrib
    #|utor-free","magpie_label":"Muse Spark 1.3 · Our Free Model","max_input_tokens":1048576,"max_output_tokens
    #|":131072,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completions"],"object":"mo
    #|del","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"light"},{"effo
    #|rt":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":1048576,"context_window":1048576,"cr
    #|eated":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Muse Spark 1.2","id":"our-free-model/muse-sp
    #|ark-1.2-contributor-free","magpie_label":"Muse Spark 1.2 · Our Free Model","max_input_tokens":1048576,"ma
    #|x_output_tokens":131072,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completions
    #|"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":
    #|"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":1048576,"context_wind
    #|ow":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"MiMo V2.6 Flash","id":"our-fr
    #|ee-model/mimo-v2.6-flash-free","magpie_label":"MiMo V2.6 Flash · Our Free Model","max_input_tokens":10485
    #|76,"max_output_tokens":131072,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/compl
    #|etions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"ef
    #|fort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":262144,"context
    #|_window":262144,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Space Bunny","id":"our-fr
    #|ee-model/space-bunny-free","magpie_label":"Space Bunny · Our Free Model","max_input_tokens":262144,"max_o
    #|utput_tokens":65536,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completions"],"
    #|object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"lig
    #|ht"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":131072,"context_window":1
    #|31072,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Longcat 2 5 Preview Free","id":"our
    #|-free-model/longcat-2.5-preview-free","magpie_label":"Longcat 2 5 Preview Free · Our Free Model","max_inp
    #|ut_tokens":131072,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_endpoints":["/v1/chat
    #|/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels"
    #|:[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":131072,"c
    #|ontext_window":131072,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Step 5 Preview Free
    #|","id":"our-free-model/step-5-preview-free","magpie_label":"Step 5 Preview Free · Our Free Model","max_in
    #|put_tokens":131072,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_endpoints":["/v1/cha
    #|t/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels
    #|":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":128000,"
    #|context_window":128000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Ling 3.0 Flash Fin
    #|","id":"our-free-model/ling-3.0-flash-fin-free","magpie_label":"Ling 3.0 Flash Fin · Our Free Model","max
    #|_input_tokens":128000,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_endpoints":["/v1/
    #|chat/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_lev
    #|els":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":12800
    #|0,"context_window":128000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Nemotron 3 Ultr
    #|a","id":"our-free-model/nemotron-3-ultra-free","magpie_label":"Nemotron 3 Ultra · Our Free Model","max_in
    #|put_tokens":128000,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_endpoints":["/v1/cha
    #|t/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels
    #|":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_length":128000,"
    #|context_window":128000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Nemotron 3.5 Light
    #|ning","id":"our-free-model/nemotron-3.5-lightning-free","magpie_label":"Nemotron 3.5 Lightning · Our Free
    #| Model","max_input_tokens":128000,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_endpo
    #|ints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_r
    #|easoning_levels":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_l
    #|ength":128000,"context_window":128000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Lin
    #|g 3 1 Flash Free","id":"our-free-model/ling-3.1-flash-free","magpie_label":"Ling 3 1 Flash Free · Our Fre
    #|e Model","max_input_tokens":128000,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_endp
    #|oints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_
    #|reasoning_levels":[{"effort":"light"},{"effort":"balanced"},{"effort":"deep"}],"type":"model"},{"context_
    #|length":1000000,"context_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"
    #|Kilo Step 5 Preview","id":"our-free-model/stepfun/step-5-preview-free","magpie_label":"Kilo Step 5 Previe
    #|w · Our Free Model","max_input_tokens":1000000,"max_output_tokens":64000,"modalities":{"input":["text","i
    #|mage"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","reasoni
    #|ng":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"mo
    #|del"},{"context_length":256000,"context_window":256000,"created":0,"created_at":"2025-01-01T00:00:00Z","d
    #|isplay_name":"Kilo Auto Free","id":"our-free-model/kilo-auto/free","magpie_label":"Kilo Auto Free · Our F
    #|ree Model","max_input_tokens":256000,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_en
    #|dpoints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supporte
    #|d_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_le
    #|ngth":1000000,"context_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Ki
    #|lo Nemotron 3 Ultra","id":"our-free-model/nvidia/nemotron-3-ultra-550b-a55b:free","magpie_label":"Kilo Ne
    #|motron 3 Ultra · Our Free Model","max_input_tokens":1000000,"max_output_tokens":65536,"modalities":{"inpu
    #|t":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","re
    #|asoning":true,"supported_reasoning_levels":[{"effort":"disabled"},{"effort":"low"},{"effort":"medium"},{"
    #|effort":"high"}],"type":"model"},{"context_length":512000,"context_window":512000,"created":0,"created_at
    #|":"2025-01-01T00:00:00Z","display_name":"Kilo Dots3-Note Preview","id":"our-free-model/dots-studio/dots-3
    #|-note-preview:free","magpie_label":"Kilo Dots3-Note Preview · Our Free Model","max_input_tokens":512000,"
    #|max_output_tokens":460800,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completio
    #|ns"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort
    #|":"disabled"},{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":2
    #|62144,"context_window":262144,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Kilo Ling 3
    #|.1 Flash","id":"our-free-model/inclusionai/ling-3.1-flash","magpie_label":"Kilo Ling 3.1 Flash · Our Free
    #| Model","max_input_tokens":262144,"max_output_tokens":32768,"modalities":{"input":["text"]},"native_endpo
    #|ints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_r
    #|easoning_levels":[{"effort":"disabled"},{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"m
    #|odel"},{"context_length":262144,"context_window":262144,"created":0,"created_at":"2025-01-01T00:00:00Z","
    #|display_name":"Kilo Laguna S 2.1","id":"our-free-model/poolside/laguna-s-2.1:free","magpie_label":"Kilo L
    #|aguna S 2.1 · Our Free Model","max_input_tokens":262144,"max_output_tokens":32768,"modalities":{"input":[
    #|"text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","reason
    #|ing":true,"supported_reasoning_levels":[{"effort":"disabled"},{"effort":"low"},{"effort":"medium"},{"effo
    #|rt":"high"}],"type":"model"},{"context_length":256000,"context_window":256000,"created":0,"created_at":"2
    #|025-01-01T00:00:00Z","display_name":"Kilo Glyph Cluster","id":"our-free-model/stealth/glyph-cluster","mag
    #|pie_label":"Kilo Glyph Cluster · Our Free Model","max_input_tokens":256000,"max_output_tokens":256000,"mo
    #|dalities":{"input":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"our
    #|-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"disabled"},{"effort":"low"},{"effo
    #|rt":"medium"},{"effort":"high"}],"type":"model"},{"context_length":65536,"context_window":65536,"created"
    #|:0,"created_at":"2025-01-01T00:00:00Z","display_name":"Kilo LFM2.5-2.6B","id":"our-free-model/liquid/lfm-
    #|2.5-2.6b:free","magpie_label":"Kilo LFM2.5-2.6B · Our Free Model","max_input_tokens":65536,"max_output_to
    #|kens":8192,"modalities":{"input":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","
    #|owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"med
    #|ium"},{"effort":"high"}],"type":"model"},{"context_length":1000000,"context_window":1000000,"created":0,"
    #|created_at":"2025-01-01T00:00:00Z","display_name":"Kilo Nemotron 3.5 Lightning","id":"our-free-model/nvid
    #|ia/nemotron-3.5-lightning:free","magpie_label":"Kilo Nemotron 3.5 Lightning · Our Free Model","max_input_
    #|tokens":1000000,"max_output_tokens":65536,"modalities":{"input":["text"]},"native_endpoints":["/v1/chat/c
    #|ompletions"],"object":"model","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[
    #|{"effort":"disabled"},{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_l
    #|ength":1048576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"K
    #|ilo Inkling Small","id":"our-free-model/thinkingmachines/inkling-small:free","magpie_label":"Kilo Inkling
    #| Small · Our Free Model","max_input_tokens":1048576,"max_output_tokens":262144,"modalities":{"input":["te
    #|xt","image"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model","r
    #|easoning":true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"typ
    #|e":"model"},{"context_length":262144,"context_window":262144,"created":0,"created_at":"2025-01-01T00:00:0
    #|0Z","display_name":"Kilo Laguna XS 2.1","id":"our-free-model/poolside/laguna-xs-2.1:free","magpie_label":
    #|"Kilo Laguna XS 2.1 · Our Free Model","max_input_tokens":262144,"max_output_tokens":32768,"modalities":{"
    #|input":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"our-free-model"
    #|,"reasoning":true,"supported_reasoning_levels":[{"effort":"disabled"},{"effort":"low"},{"effort":"medium"
    #|},{"effort":"high"}],"type":"model"},{"context_length":256000,"context_window":256000,"created":0,"create
    #|d_at":"2025-01-01T00:00:00Z","display_name":"Kilo North Mini Code","id":"our-free-model/cohere/north-mini
    #|-code:free","magpie_label":"Kilo North Mini Code · Our Free Model","max_input_tokens":256000,"max_output_
    #|tokens":64000,"modalities":{"input":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model
    #|","owned_by":"our-free-model","reasoning":true,"supported_reasoning_levels":[{"effort":"disabled"},{"effo
    #|rt":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model"},{"context_length":1048576,"context_wind
    #|ow":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Exo Free","id":"opencode-zen-
    #|free/exo-free","magpie_label":"Exo Free · OpenCode Zen Free","max_input_tokens":1048576,"max_output_token
    #|s":131072,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completions"],"object":"m
    #|odel","owned_by":"opencode-zen-free","reasoning":true,"supported_reasoning_levels":[{"effort":"high"}],"t
    #|ype":"model"},{"context_length":160000,"context_window":160000,"created":0,"created_at":"2025-01-01T00:00
    #|:00Z","display_name":"Big Pickle","id":"opencode-zen-free/big-pickle","magpie_label":"Big Pickle · OpenCo
    #|de Zen Free","max_input_tokens":160000,"max_output_tokens":32000,"modalities":{"input":["text"]},"native_
    #|endpoints":["/v1/chat/completions"],"object":"model","owned_by":"opencode-zen-free","reasoning":true,"sup
    #|ported_reasoning_levels":[],"type":"model"},{"context_length":1048576,"context_window":1048576,"created":
    #|0,"created_at":"2025-01-01T00:00:00Z","display_name":"Muse Spark 1.3 Free","id":"opencode-zen-free/muse-s
    #|park-1.3-contributor-free","magpie_label":"Muse Spark 1.3 Free · OpenCode Zen Free","max_input_tokens":10
    #|48576,"max_output_tokens":131072,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/respons
    #|es"],"object":"model","owned_by":"opencode-zen-free","reasoning":true,"supported_reasoning_levels":[{"eff
    #|ort":"minimal"},{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}],"type":"model"
    #|},{"context_length":200000,"context_window":200000,"created":0,"created_at":"2025-01-01T00:00:00Z","displ
    #|ay_name":"MiMo-V2.6-Flash Free","id":"opencode-zen-free/mimo-v2.6-flash-free","magpie_label":"MiMo-V2.6-F
    #|lash Free · OpenCode Zen Free","max_input_tokens":200000,"max_output_tokens":32000,"modalities":{"input":
    #|["text","image"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"opencode-zen-f
    #|ree","reasoning":true,"supported_reasoning_levels":[],"type":"model"},{"context_length":524288,"context_w
    #|indow":524288,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Space Bunny Free","id":"ope
    #|ncode-zen-free/space-bunny-free","magpie_label":"Space Bunny Free · OpenCode Zen Free","max_input_tokens"
    #|:524288,"max_output_tokens":524288,"modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/
    #|completions"],"object":"model","owned_by":"opencode-zen-free","reasoning":true,"supported_reasoning_level
    #|s":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"type":"m
    #|odel"},{"context_length":1000000,"context_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z"
    #|,"display_name":"LongCat 2.5 Preview Free","id":"opencode-zen-free/longcat-2.5-preview-free","magpie_labe
    #|l":"LongCat 2.5 Preview Free · OpenCode Zen Free","max_input_tokens":1000000,"max_output_tokens":131072,"
    #|modalities":{"input":["text","image"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owne
    #|d_by":"opencode-zen-free","reasoning":true,"supported_reasoning_levels":[],"type":"model"},{"context_leng
    #|th":1000000,"context_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Step
    #| 5 Preview Free","id":"opencode-zen-free/step-5-preview-free","magpie_label":"Step 5 Preview Free · OpenC
    #|ode Zen Free","max_input_tokens":1000000,"max_output_tokens":65536,"modalities":{"input":["text","image"]
    #|},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"opencode-zen-free","reasoning"
    #|:true,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"type":"model
    #|"},{"context_length":262144,"context_window":262144,"created":0,"created_at":"2025-01-01T00:00:00Z","disp
    #|lay_name":"Ling 3.0 Flash Fin Free","id":"opencode-zen-free/ling-3.0-flash-fin-free","magpie_label":"Ling
    #| 3.0 Flash Fin Free · OpenCode Zen Free","max_input_tokens":262144,"max_output_tokens":32768,"modalities"
    #|:{"input":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"opencode-zen
    #|-free","reasoning":true,"supported_reasoning_levels":[],"type":"model"},{"context_length":1000000,"contex
    #|t_window":1000000,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"Nemotron 3 Ultra Free",
    #|"id":"opencode-zen-free/nemotron-3-ultra-free","magpie_label":"Nemotron 3 Ultra Free · OpenCode Zen Free"
    #|,"max_input_tokens":1000000,"max_output_tokens":128000,"modalities":{"input":["text"]},"native_endpoints"
    #|:["/v1/chat/completions"],"object":"model","owned_by":"opencode-zen-free","reasoning":true,"supported_rea
    #|soning_levels":[],"type":"model"},{"context_length":262144,"context_window":262144,"created":0,"created_a
    #|t":"2025-01-01T00:00:00Z","display_name":"Nemotron 3.5 Lightning Free","id":"opencode-zen-free/nemotron-3
    #|.5-lightning-free","magpie_label":"Nemotron 3.5 Lightning Free · OpenCode Zen Free","max_input_tokens":26
    #|2144,"max_output_tokens":262144,"modalities":{"input":["text"]},"native_endpoints":["/v1/chat/completions
    #|"],"object":"model","owned_by":"opencode-zen-free","reasoning":true,"supported_reasoning_levels":[],"type
    #|":"model"},{"context_length":262144,"context_window":262144,"created":0,"created_at":"2025-01-01T00:00:00
    #|Z","display_name":"Ling 3.1 Flash Free","id":"opencode-zen-free/ling-3.1-flash-free","magpie_label":"Ling
    #| 3.1 Flash Free · OpenCode Zen Free","max_input_tokens":262144,"max_output_tokens":32768,"modalities":{"i
    #|nput":["text"]},"native_endpoints":["/v1/chat/completions"],"object":"model","owned_by":"opencode-zen-fre
    #|e","reasoning":true,"supported_reasoning_levels":[],"type":"model"}],"first_id":"group/auto-gpt-6-luna","
    #|has_more":false,"last_id":"opencode-zen-free/ling-3.1-flash-free","object":"list"}
  )
}
