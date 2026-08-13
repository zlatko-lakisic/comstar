/** Centered AO progress card with slide-replace animations. */

const HOLD_MS = 1800;
const ANIM_MS = 360;

/**
 * @param {HTMLElement} root
 */
export function createAoActivity(root) {
  root.innerHTML = `<div class="ao-activity__slot" aria-live="polite"></div>`;
  const slot = root.querySelector('.ao-activity__slot');
  let current = null;
  let holdTimer = null;
  let animating = false;

  function clearHold() {
    if (holdTimer) {
      clearTimeout(holdTimer);
      holdTimer = null;
    }
  }

  function makeCard(message, processing) {
    const el = document.createElement('div');
    el.className = 'ao-activity__card' + (processing ? ' is-working' : '');
    el.textContent = message;
    return el;
  }

  function exitCard(card, done) {
    if (!card) {
      done?.();
      return;
    }
    card.classList.remove('is-working', 'is-enter');
    card.classList.add('is-exit');
    setTimeout(() => {
      card.remove();
      done?.();
    }, ANIM_MS);
  }

  /**
   * @param {{ active: boolean, message?: string, processing?: boolean }} data
   */
  function apply(data) {
    if (!data || data.active === false) {
      clearHold();
      if (!current) return;
      holdTimer = setTimeout(() => {
        const card = current;
        current = null;
        exitCard(card);
      }, HOLD_MS);
      return;
    }

    const message = (data.message || '').trim();
    if (!message) return;
    clearHold();

    const processing = data.processing !== false;
    if (current && current.textContent === message) {
      current.classList.toggle('is-working', processing);
      return;
    }

    if (animating) {
      // Drop intermediate frames mid-animation; next apply wins.
    }
    animating = true;
    const next = makeCard(message, processing);
    next.classList.add('is-enter');
    const prev = current;
    current = next;
    slot.appendChild(next);
    // Force reflow so enter animation runs.
    void next.offsetWidth;
    next.classList.add('is-in');
    if (prev) {
      exitCard(prev, () => {
        animating = false;
      });
    } else {
      setTimeout(() => {
        animating = false;
      }, ANIM_MS);
    }
  }

  function clearNow() {
    clearHold();
    const card = current;
    current = null;
    exitCard(card);
  }

  return { apply, clearNow };
}
