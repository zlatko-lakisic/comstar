import { ComstarAvatar } from './avatar/avatar.js';

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

let heroAvatar = null;
let currentEmblem = 'starburst';

function mountAvatar(el, opts = {}) {
  if (!el) return null;
  return new ComstarAvatar(el, {
    emblem: opts.emblem || 'starburst',
    emblemScale: opts.emblemScale ?? 0.68,
    bloom: opts.bloom ?? 2,
    maxFps: opts.maxFps ?? (reduced ? 8 : 24),
  });
}

function runHeroWalkup(avatar) {
  if (!avatar) return;
  if (reduced) {
    avatar.setState('engaged');
    return;
  }
  avatar.setState('ambient');
  window.setTimeout(() => avatar.setState('noticed'), 800);
  window.setTimeout(() => avatar.setState('engaged'), 1600);
}

function initHero() {
  const stage = document.getElementById('hero-stage');
  heroAvatar = mountAvatar(stage, { emblem: currentEmblem });
  runHeroWalkup(heroAvatar);
}

function initPresets() {
  const buttons = document.querySelectorAll('[data-preset]');
  buttons.forEach((btn) => {
    const id = btn.getAttribute('data-preset');
    const stage = btn.querySelector('[data-preset-stage]');
    const mini = mountAvatar(stage, {
      emblem: id,
      emblemScale: 0.72,
      bloom: 0,
      maxFps: reduced ? 6 : 12,
    });
    if (mini) {
      mini.setState(reduced ? 'engaged' : 'ambient');
      if (!reduced) {
        window.setTimeout(() => mini.setState('engaged'), 400 + Math.random() * 600);
      }
    }

    btn.addEventListener('click', () => {
      currentEmblem = id;
      buttons.forEach((b) => b.setAttribute('aria-pressed', String(b === btn)));
      if (heroAvatar) {
        heroAvatar.dispose();
        heroAvatar = null;
      }
      const stageEl = document.getElementById('hero-stage');
      heroAvatar = mountAvatar(stageEl, { emblem: currentEmblem });
      if (heroAvatar) heroAvatar.setState('engaged');
      document.getElementById('hero')?.scrollIntoView({
        behavior: reduced ? 'auto' : 'smooth',
      });
    });
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

function initUtterances() {
  const items = document.querySelectorAll('.utterance');
  items.forEach((item) => {
    item.addEventListener('click', () => {
      const open = item.classList.contains('is-open');
      items.forEach((i) => i.classList.remove('is-open'));
      if (!open) item.classList.add('is-open');
    });
  });
}

initHero();
initPresets();
initReveal();
initUtterances();
