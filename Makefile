.PHONY: demo demo-record-prep demo-clean

demo:
	./scripts/demo/run_full_demo.sh

demo-record-prep:
	@if command -v opam >/dev/null 2>&1; then eval "$$(opam env --switch=zxcaml-p1)"; fi; zig build
	./scripts/demo/00_setup.sh
	./scripts/demo/01_build.sh
	@printf 'READY TO RECORD\n'

demo-clean:
	./scripts/demo/05_teardown.sh
	rm -rf .surfpool scripts/demo/.keypairs scripts/demo/.program_id scripts/demo/.surfpool.pid out/hackathon_greet.so
	@printf 'Demo generated artifacts removed.\n'
