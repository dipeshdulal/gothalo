# gothalo website

Astro + Starlight. The landing page is `/`, the docs live under `/docs/`.

```sh
npm install
npm run dev      # prepare-docs, then astro dev
npm run build    # prepare-docs, then astro build -> dist/
```

`scripts/prepare-docs.mjs` copies the repo's `docs/*.md` and `CONTRACT.md` into
`src/content/docs/docs/` with frontmatter and rewritten links. Those directories are
gitignored; edit the source markdown, not the copies.

`.github/workflows/website.yml` builds on pushes to `main` that touch `website/`,
`docs/`, `README.md` or `CONTRACT.md`, and deploys to GitHub Pages.

Env: `SITE` (default `https://dipeshdulal.github.io`), `BASE` (default `/gothalo`), or
`CUSTOM_DOMAIN` to serve from a domain root with no base path.
