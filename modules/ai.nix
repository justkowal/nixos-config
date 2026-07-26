{ config, pkgs, ... }:

{
  # 1. System-wide Ollama daemon with AMD ROCm GPU acceleration (RX 6700 XT)
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    environmentVariables = {
      HSA_OVERRIDE_GFX_VERSION = "10.3.0"; # Navi 22 GPU architecture override
      OLLAMA_NUM_PARALLEL = "2";
    };
    rocmOverrideGfx = "10.3.0";
    loadModels = [
      "nomic-embed-text"
      "hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
      "hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF"
      "hf.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF"
    ];
  };

  # 2. Local SearXNG privacy-respecting Meta-Search Engine (for LLM Web Search RAG)
  services.searx = {
    enable = true;
    settings = {
      server = {
        port = 8888;
        bind_address = "127.0.0.1";
        secret_key = "nixos-local-searxng-ai-secret";
      };
      search = {
        safe_search = 0;
        autocomplete = "google";
        formats = [ "html" "json" ];
      };
      engines = [
        { name = "duckduckgo"; engine = "duckduckgo"; shortcut = "ddg"; }
        { name = "google"; engine = "google"; shortcut = "g"; }
        { name = "github"; engine = "github"; shortcut = "gh"; }
        { name = "wikipedia"; engine = "wikipedia"; shortcut = "wp"; }
      ];
    };
  };

  # 3. Open WebUI with Automatic Vector Document RAG & Web Search RAG
  services.open-webui = {
    enable = true;
    port = 11111;
    environment = {
      OLLAMA_API_BASE_URL = "http://127.0.0.1:11434";
      ENABLE_SIGNUP = "true";
      WEBUI_AUTH = "false";
      
      # Vector Document RAG & File Browsing Configuration using nomic-embed-text over Ollama ROCm
      VECTOR_DB = "chroma";
      RAG_EMBEDDING_ENGINE = "ollama";
      RAG_EMBEDDING_MODEL = "nomic-embed-text";
      OLLAMA_EMBED_BASE_URL = "http://127.0.0.1:11434";
      RAG_TOP_K = "5";
      RAG_RELEVANCE_THRESHOLD = "0.1";
      ENABLE_RAG_HYBRID_SEARCH = "True";
      ENABLE_RAG_LOCAL_WEB_FETCH = "True";
      DOCS_DIR = "/home/justkowal";
      RAG_UPLOAD_DIR = "/home/justkowal";
      
      # Real-Time Web Search RAG Configuration (SearXNG)
      ENABLE_RAG_WEB_SEARCH = "True";
      RAG_WEB_SEARCH_ENGINE = "searxng";
      SEARXNG_QUERY_URL = "http://127.0.0.1:8888/search?q=<query>";
      RAG_WEB_SEARCH_RESULT_COUNT = "5";
      RAG_WEB_SEARCH_CONCURRENT_REQUESTS = "10";
    };
  };

  # System packages for local AI interaction & ambient services
  environment.systemPackages = with pkgs; [
    oterm           # TUI client for Ollama
    poppler-utils   # pdftotext for AI PDF Q&A
    inotify-tools   # Filesystem watcher for auto-organizer daemon
  ];
}
