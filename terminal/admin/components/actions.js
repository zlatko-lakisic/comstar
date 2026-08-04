import { mountEmblem } from '/kiosk/emblem.js';

async function runButton(btn, label, work) {
  const idle = btn.dataset.label || label;
  btn.dataset.label = idle;
  btn.disabled = true;
  btn.classList.remove('is-ok', 'is-fail');
  btn.textContent = btn.dataset.pending || 'Working…';
  const errEl = btn.parentElement?.querySelector('.action-err');
  if (errEl) errEl.remove();
  try {
    await work();
    btn.classList.add('is-ok');
    btn.textContent = idle;
    setTimeout(() => btn.classList.remove('is-ok'), 1200);
  } catch (e) {
    btn.classList.add('is-fail');
    btn.textContent = idle;
    const p = document.createElement('p');
    p.className = 'action-err';
    p.textContent = e.message || String(e);
    btn.parentElement?.appendChild(p);
    setTimeout(() => btn.classList.remove('is-fail'), 1600);
  } finally {
    btn.disabled = false;
  }
}

function holdButton(btn, ms, onFire) {
  let timer = null;
  let start = 0;
  const fill = btn.querySelector('.hold-fill');

  function cancel() {
    if (timer) cancelAnimationFrame(timer);
    timer = null;
    if (fill) fill.style.width = '0';
  }

  function tick(now) {
    const p = Math.min(1, (now - start) / ms);
    if (fill) fill.style.width = `${p * 100}%`;
    if (p >= 1) {
      cancel();
      onFire();
      return;
    }
    timer = requestAnimationFrame(tick);
  }

  btn.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    start = performance.now();
    timer = requestAnimationFrame(tick);
  });
  btn.addEventListener('pointerup', cancel);
  btn.addEventListener('pointerleave', cancel);
  btn.addEventListener('pointercancel', cancel);
}

export function createActions(root, modalRoot, { api, onDanger }) {
  root.innerHTML = `
    <div class="actions-row">
      <button type="button" class="btn" data-restart="bridge" data-pending="Restarting…">Restart bridge</button>
      <button type="button" class="btn" data-restart="audio" data-pending="Restarting…">audio</button>
      <button type="button" class="btn" data-restart="kiosk" data-pending="Restarting…">kiosk</button>
      <button type="button" class="btn" data-restart="stt" data-pending="Restarting…">stt</button>
    </div>
    <div class="actions-row">
      <button type="button" class="btn" id="sleepEnter" data-pending="Sleeping…">Sleep</button>
      <button type="button" class="btn" id="sleepExit" data-pending="Waking…">Wake</button>
    </div>
    <div class="danger">
      <p class="danger__title">Danger</p>
      <div class="actions-row">
        <button type="button" class="btn btn--danger btn--hold" id="restartAll"><span class="hold-fill"></span><span>Restart all</span></button>
        <button type="button" class="btn btn--danger" id="rebootBtn">Reboot terminal</button>
      </div>
    </div>
  `;

  root.querySelectorAll('[data-restart]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const unit = btn.getAttribute('data-restart');
      runButton(btn, btn.textContent, () => api.post('/api/restart', { unit }));
    });
  });

  root.querySelector('#sleepEnter').addEventListener('click', (e) => {
    runButton(e.currentTarget, 'Sleep', () => api.post('/api/sleep', { action: 'enter' }));
  });
  root.querySelector('#sleepExit').addEventListener('click', (e) => {
    runButton(e.currentTarget, 'Wake', () => api.post('/api/sleep', { action: 'exit' }));
  });

  holdButton(root.querySelector('#restartAll'), 800, () => {
    const btn = root.querySelector('#restartAll');
    runButton(btn, 'Restart all', async () => {
      onDanger?.();
      await api.post('/api/restart', { unit: 'all' });
    });
  });

  root.querySelector('#rebootBtn').addEventListener('click', () => {
    openRebootModal(modalRoot, async () => {
      onDanger?.();
      await api.post('/api/reboot', { confirm: 'reboot' });
    });
  });
}

function openRebootModal(modalRoot, onConfirm) {
  modalRoot.innerHTML = `
    <div class="modal" role="dialog" aria-modal="true">
      <div class="modal__card">
        <div class="modal__emblem" id="modalEmblem"></div>
        <p class="modal__text">This will reboot the terminal. Kiosk, audio and bridge will be unavailable for roughly 45 seconds.</p>
        <input class="modal__input" id="rebootInput" placeholder="type reboot" autocomplete="off" />
        <div class="modal__actions">
          <button type="button" class="btn" id="rebootCancel">Cancel</button>
          <button type="button" class="btn btn--danger" id="rebootGo" disabled>Reboot</button>
        </div>
      </div>
    </div>`;
  const emblem = mountEmblem(modalRoot.querySelector('#modalEmblem'), {
    bloom: 3, scale: 0.65, maxFps: 12, bg: true,
  });
  emblem.setState('unreachable');
  const input = modalRoot.querySelector('#rebootInput');
  const go = modalRoot.querySelector('#rebootGo');
  input.focus();
  input.addEventListener('input', () => {
    go.disabled = input.value.trim() !== 'reboot';
  });
  const close = () => {
    emblem.destroy();
    modalRoot.innerHTML = '';
  };
  modalRoot.querySelector('#rebootCancel').addEventListener('click', close);
  modalRoot.querySelector('.modal').addEventListener('keydown', (e) => {
    if (e.key === 'Escape') close();
  });
  go.addEventListener('click', async () => {
    if (input.value.trim() !== 'reboot') return;
    go.disabled = true;
    try {
      await onConfirm();
      close();
    } catch (e) {
      go.disabled = false;
      alert(e.message || String(e));
    }
  });
}
