.PHONY: demo demo-record-prep demo-clean demo-clean-deep slides-install slides-dev slides-export-pdf slides-clean clean

demo:
	./scripts/demo/run_full_demo.sh

demo-record-prep:
	@if command -v opam >/dev/null 2>&1; then eval "$$(opam env --switch=zxcaml-p1)"; fi; zig build
	./scripts/demo/00_setup.sh
	./scripts/demo/01_build.sh
	$(MAKE) slides-export-pdf
	@printf 'READY TO RECORD\n'
	@printf 'Slide PDFs:\n'
	@printf '  out/slides/zh.pdf\n'
	@printf '  out/slides/en.pdf\n'

demo-clean:
	./scripts/demo/05_teardown.sh
	rm -rf .surfpool scripts/demo/.keypairs scripts/demo/.program_id scripts/demo/.surfpool.pid out/hackathon_greet.so
	@printf 'Demo generated artifacts removed.\n'

slides-install:
	cd slides && pnpm install --frozen-lockfile

slides-dev:
	@printf 'Starting Slidev dev server on http://localhost:3030 (Ctrl-C to stop).\n'
	cd slides && pnpm dev

slides-export-pdf:
	mkdir -p out/slides
	cd slides && pnpm exec slidev export slides.zh.md --output ../out/slides/zh.pdf --timeout 120000 --wait 5000
	cd slides && pnpm exec slidev export slides.en.md --output ../out/slides/en.pdf --timeout 120000 --wait 5000

slides-clean:
	rm -rf out/slides

clean:
	$(MAKE) demo-clean
	$(MAKE) slides-clean
	@printf '[clean] done: demo-clean + slides-clean completed; anchor_reference/target preserved (use demo-clean-deep to remove it).\n'

demo-clean-deep:
	@if [ -d scripts/demo/anchor_reference/target ]; then \
		freed=$$(du -sh scripts/demo/anchor_reference/target 2>/dev/null | awk '{print $$1}'); \
		rm -rf scripts/demo/anchor_reference/target; \
		printf '[demo-clean-deep] removed scripts/demo/anchor_reference/target (freed approximately %s).\n' "$$freed"; \
	else \
		printf '[demo-clean-deep] no scripts/demo/anchor_reference/target directory found.\n'; \
	fi
