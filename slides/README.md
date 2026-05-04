# ZxCaml Colosseum Slidev Decks

## Install

```sh
pnpm install --frozen-lockfile
```

## Run

```sh
pnpm dev
```

The default development deck is `slides.zh.md`. To preview another deck:

```sh
pnpm exec slidev slides.en.md
```

## Build

```sh
pnpm build
pnpm exec slidev build slides.en.md --base ./
```

## Export

```sh
pnpm export
pnpm exec slidev export slides.en.md --output ../out/slides/en.pdf
```

Export writes PDFs under `../out/slides/`. Slidev export uses Playwright Chromium.
On a fresh machine, the first install/export path downloads Playwright Chromium if it is not already cached; expect roughly a 150 MB one-time download.

## Clean

```sh
pnpm clean
```
