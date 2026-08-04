import { mountHero } from './avatar/hero-avatar.js';

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

let hero = null;
let currentEmblem = 'starburst';

function remountHero(emblem) {
  const el = document.getElementById('hero-avatar');
  if (!el) return;
  if (hero) hero.destroy();
  currentEmblem = emblem || currentEmblem;
  hero = mountHero(el, {
    emblem: currentEmblem,
    caption: true,
    animate: !reduced,
  });
}

function initPresets() {
  const buttons = document.querySelectorAll('[data-preset]');
  buttons.forEach((btn) => {
    const id = btn.getAttribute('data-preset');
    const stage = btn.querySelector('[data-preset-stage]');
    if (stage) {
      mountHero(stage, {
        emblem: id,
        caption: false,
        animate: false,
        size: 'thumb',
        bloom: 0,
      });
    }

    btn.addEventListener('click', () => {
      buttons.forEach((b) => b.setAttribute('aria-pressed', String(b === btn)));
      remountHero(id);
      document.getElementById('hero')?.scrollIntoView({
        behavior: reduced ? 'auto' : 'smooth',
      });
    });
  });

  buttons.forEach((b) => {
    b.setAttribute('aria-pressed', String(b.getAttribute('data-preset') === currentEmblem));
  });
}

function initReveal() {
  if (reduced) {
    document.querySelectorAll('.reveal').forEach((el) => el.classList.add('is-visible'));
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          io.unobserve(entry.target);
        }
      }
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0.12 },
  );
  document.querySelectorAll('.reveal').forEach((el) => io.observe(el));
}

function initStickyNav() {
  const nav = document.getElementById('sticky-nav');
  const heroEl = document.getElementById('hero');
  if (!nav || !heroEl) return;

  const links = [...nav.querySelectorAll('[data-nav-section]')];
  const sections = links
    .map((a) => document.getElementById(a.getAttribute('data-nav-section')))
    .filter(Boolean);

  const heroIo = new IntersectionObserver(
    ([entry]) => {
      nav.classList.toggle('is-visible', !entry.isIntersecting);
    },
    { threshold: 0.05 },
  );
  heroIo.observe(heroEl);

  const sectionIo = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const id = entry.target.id;
        links.forEach((a) => {
          const on = a.getAttribute('data-nav-section') === id;
          a.classList.toggle('is-active', on);
          if (on) a.setAttribute('aria-current', 'true');
          else a.removeAttribute('aria-current');
        });
      }
    },
    { rootMargin: '-40% 0px -50% 0px', threshold: 0 },
  );
  sections.forEach((s) => sectionIo.observe(s));
}

remountHero('starburst');
initPresets();
initReveal();
initStickyNav();
