use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();
log_level('info');

run_tests;

__DATA__

=== TEST 1: os.getenv prefix collision - short env first
--- main_config
env KUBERNETES_CLIENT_TOKEN=some-token;
env KUBERNETES_CLIENT_TOKEN_FILE=/path/to/token;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("TOKEN=", os.getenv("KUBERNETES_CLIENT_TOKEN"))
            ngx.say("TOKEN_FILE=", os.getenv("KUBERNETES_CLIENT_TOKEN_FILE"))
        }
    }
--- request
GET /t
--- response_body
TOKEN=some-token
TOKEN_FILE=/path/to/token



=== TEST 2: os.getenv prefix collision - long env first
--- main_config
env KUBERNETES_CLIENT_TOKEN_FILE=/path/to/token;
env KUBERNETES_CLIENT_TOKEN=some-token;
--- config
    location /t {
        content_by_lua_block {
            ngx.say("TOKEN=", os.getenv("KUBERNETES_CLIENT_TOKEN"))
            ngx.say("TOKEN_FILE=", os.getenv("KUBERNETES_CLIENT_TOKEN_FILE"))
        }
    }
--- request
GET /t
--- response_body
TOKEN=some-token
TOKEN_FILE=/path/to/token



=== TEST 3: init_worker phase os.getenv prefix collision
--- main_config
env KUBERNETES_CLIENT_TOKEN=some-token;
env KUBERNETES_CLIENT_TOKEN_FILE=/path/to/token;
--- extra_init_worker_by_lua
        ngx.shared["test"]:set("iw_token", os.getenv("KUBERNETES_CLIENT_TOKEN") or "NIL")
        ngx.shared["test"]:set("iw_token_file", os.getenv("KUBERNETES_CLIENT_TOKEN_FILE") or "NIL")
--- config
    location /t {
        content_by_lua_block {
            ngx.say("TOKEN=", ngx.shared["test"]:get("iw_token"))
            ngx.say("TOKEN_FILE=", ngx.shared["test"]:get("iw_token_file"))
        }
    }
--- request
GET /t
--- response_body
TOKEN=some-token
TOKEN_FILE=/path/to/token
