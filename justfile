binary_name := if os() == "windows" { "server.exe" } else { "server" }
out_path := "bin/" + binary_name
archive_name := "server.7z"

run:
    @mkdir -p bin
    @odin run src --out:{{ out_path }}

build:
    @mkdir -p bin
    @odin build src --out:{{ out_path }}

bundle: build
    @mkdir -p dist
    @cp {{ out_path }} dist/
    @cp lua5.1.dll dist/ 2>/dev/null || cp bin/lua5.1.dll dist/ 2>/dev/null || true
    @cp .luarc.json dist/
    @cp config.ini dist/
    @cp keeper.dll dist/
    @cp -r scripts dist/
    @rm -f {{ archive_name }}
    7z a -ttar -snl {{ archive_name }} ./dist/* > /dev/null
    @rm -rf dist
