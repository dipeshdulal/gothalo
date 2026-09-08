// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// A custom domain serves from the root; GitHub Pages serves under /gothalo.
const customDomain = process.env.CUSTOM_DOMAIN;
const site = customDomain || process.env.SITE || 'https://dipeshdulal.github.io';
const base = customDomain ? '/' : (process.env.BASE ?? '/gothalo');

const fonts =
  'family=Young+Serif&family=IBM+Plex+Sans:wght@400;500;600' +
  '&family=JetBrains+Mono:wght@400;500&family=Noto+Sans+Devanagari:wght@400;500&display=swap';

export default defineConfig({
  site,
  base,
  integrations: [
    starlight({
      title: 'gothalo',
      logo: { src: './src/assets/mark.png', alt: 'gothalo' },
      description:
        'A self-hosted phone remote for Herdr: see which coding agents are working, blocked or done, get pushed when one needs you, and answer from your phone over your own Tailscale network.',
      favicon: '/favicon.png',
      customCss: ['./src/styles/tokens.css', './src/styles/starlight.css'],
      lastUpdated: true,
      editLink: { baseUrl: 'https://github.com/dipeshdulal/gothalo/edit/main/' },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/dipeshdulal/gothalo' },
      ],
      head: [
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
        {
          tag: 'link',
          attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: 'anonymous' },
        },
        {
          tag: 'link',
          attrs: { rel: 'stylesheet', href: `https://fonts.googleapis.com/css2?${fonts}` },
        },
      ],
      sidebar: [
        { label: 'Landing page', link: '/' },
        {
          label: 'Start here',
          items: [
            { label: 'What gothalo is', slug: 'docs' },
            { label: 'Install', slug: 'docs/install' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { slug: 'docs/guides/push' },
            { slug: 'docs/guides/agent-integration' },
            { slug: 'docs/guides/testing' },
          ],
        },
        {
          label: 'Reference',
          items: [{ slug: 'docs/reference/architecture' }, { slug: 'docs/reference/api' }],
        },
        { label: 'Contracts', items: [{ autogenerate: { directory: 'docs/contracts' } }] },
        {
          label: 'Project',
          items: [{ slug: 'docs/project/roadmap' }, { slug: 'docs/project/decisions' }],
        },
        {
          label: 'Elsewhere',
          items: [
            {
              label: 'Releases',
              link: 'https://github.com/dipeshdulal/gothalo/releases',
              attrs: { target: '_blank' },
            },
            {
              label: 'GitHub',
              link: 'https://github.com/dipeshdulal/gothalo',
              attrs: { target: '_blank' },
            },
          ],
        },
      ],
    }),
  ],
});
