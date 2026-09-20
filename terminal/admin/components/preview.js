/** Admin Live view — wayvnc panel (noVNC) + camera MJPEG. */

import RFB from '../vendor/novnc/core/rfb.js';

function paneStatus(el, text, tone) {
  if (!el) return;
  el.textContent = text;
  el.classList.remove('is-live', 'is-bad', 'is-amber');
  if (tone === 'live') el.classList.add('is-live');
  else if (tone === 'bad') el.classList.add('is-bad');
  else if (tone === 'amber') el.classList.add('is-amber');
}

function wsUrlFromApi(api, path) {
  const rel = api.url(path);
  const u = new URL(rel, location.href);
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
  return u.toString();
}

export function createLivePreview({ api, modalRoot, button }) {
  let open = false;
  let onKey = null;
  let rfb = null;

  function setButtonState(preview) {
    if (!button) return;
    const enabled = preview?.enabled !== false;
    const panelOk = !!preview?.panel?.available;
    const camOk = !!preview?.camera?.available;
    button.disabled = !enabled;
    button.title = !enabled
      ? 'Live preview disabled (admin.preview_enabled)'
      : panelOk || camOk
        ? 'Open live panel + camera preview'
        : 'Preview may be unavailable — open for details';
    button.classList.toggle('is-dim', enabled && !panelOk && !camOk);
  }

  function stopStreams() {
    if (rfb) {
      try {
        rfb.disconnect();
      } catch (_) {
        // ignore
      }
      rfb = null;
    }
    const panelImg = modalRoot.querySelector('#previewPanelImg');
    const camImg = modalRoot.querySelector('#previewCameraImg');
    if (panelImg) {
      panelImg.removeAttribute('src');
      panelImg.onload = null;
      panelImg.onerror = null;
    }
    if (camImg) {
      camImg.removeAttribute('src');
      camImg.onload = null;
      camImg.onerror = null;
    }
  }

  function close() {
    if (!open) return;
    open = false;
    stopStreams();
    if (onKey) {
      document.removeEventListener('keydown', onKey);
      onKey = null;
    }
    modalRoot.innerHTML = '';
  }

  function startWayvnc(screenEl, panelStatus, hint) {
    paneStatus(panelStatus, 'connecting…', 'amber');
    const url = wsUrlFromApi(api, '/api/preview/panel.ws');
    try {
      rfb = new RFB(screenEl, url, {
        wsProtocols: ['binary'],
      });
      rfb.viewOnly = true;
      rfb.scaleViewport = true;
      rfb.resizeSession = false;
      rfb.addEventListener('connect', () => {
        paneStatus(panelStatus, 'live (wayvnc)', 'live');
      });
      rfb.addEventListener('disconnect', (e) => {
        const clean = e?.detail?.clean;
        if (open) {
          paneStatus(
            panelStatus,
            clean ? 'disconnected' : (hint || 'unavailable'),
            clean ? 'amber' : 'bad',
          );
        }
      });
      rfb.addEventListener('securityfailure', () => {
        paneStatus(panelStatus, hint || 'auth failed', 'bad');
      });
    } catch (e) {
      paneStatus(panelStatus, e.message || 'wayvnc failed', 'bad');
    }
  }

  function startGrim(panelImg, panelStatus, hint) {
    paneStatus(panelStatus, 'connecting…', 'amber');
    panelImg.onload = () => paneStatus(panelStatus, 'live (grim)', 'live');
    panelImg.onerror = () =>
      paneStatus(panelStatus, hint || 'unavailable', 'bad');
    panelImg.src = api.url('/api/preview/panel.mjpeg');
  }

  async function openModal() {
    if (open) return;
    open = true;

    let status = null;
    try {
      status = await api.get('/api/preview/status');
    } catch (e) {
      status = { enabled: false, error: e.message || String(e) };
    }

    const backend = status?.panel?.backend || 'wayvnc';
    const useWayvnc = backend === 'wayvnc';

    modalRoot.innerHTML = `
      <div class="modal modal--preview" role="dialog" aria-modal="true" aria-label="Live view">
        <div class="modal__card modal__card--preview">
          <div class="preview-head">
            <h2 class="preview-title">Live view</h2>
            <button type="button" class="btn btn--ghost" id="previewClose" aria-label="Close">Close</button>
          </div>
          <p class="preview-note">Panel is view-only wayvnc while this dialog is open. Camera frames are not recorded.</p>
          <div class="preview-grid">
            <div class="preview-pane">
              <div class="preview-pane__label">Panel</div>
              <div class="preview-pane__frame${useWayvnc ? ' preview-pane__frame--vnc' : ''}">
                ${useWayvnc
                  ? '<div id="previewPanelScreen" class="preview-vnc"></div>'
                  : '<img id="previewPanelImg" alt="Hallway panel" />'}
              </div>
              <p class="preview-pane__status mono" id="previewPanelStatus">connecting…</p>
            </div>
            <div class="preview-pane">
              <div class="preview-pane__label">Camera</div>
              <div class="preview-pane__frame">
                <img id="previewCameraImg" alt="Hallway camera" />
              </div>
              <p class="preview-pane__status mono" id="previewCameraStatus">connecting…</p>
            </div>
          </div>
        </div>
      </div>
    `;

    const panelStatus = modalRoot.querySelector('#previewPanelStatus');
    const camStatus = modalRoot.querySelector('#previewCameraStatus');
    const camImg = modalRoot.querySelector('#previewCameraImg');

    modalRoot.querySelector('#previewClose')?.addEventListener('click', close);
    modalRoot.querySelector('.modal--preview')?.addEventListener('click', (e) => {
      if (e.target.classList.contains('modal--preview')) close();
    });
    onKey = (e) => {
      if (e.key === 'Escape') close();
    };
    document.addEventListener('keydown', onKey);

    if (status?.enabled === false) {
      paneStatus(panelStatus, status.error || 'preview disabled', 'bad');
      paneStatus(camStatus, status.error || 'preview disabled', 'bad');
      return;
    }

    const panelHint = status?.panel?.hint;
    const camHint = status?.camera?.hint;

    if (status?.panel?.available === false) {
      paneStatus(panelStatus, panelHint || 'unavailable', 'bad');
    } else if (useWayvnc) {
      const screen = modalRoot.querySelector('#previewPanelScreen');
      startWayvnc(screen, panelStatus, panelHint);
    } else {
      const panelImg = modalRoot.querySelector('#previewPanelImg');
      startGrim(panelImg, panelStatus, panelHint);
    }

    if (status?.camera?.available === false) {
      paneStatus(camStatus, camHint || 'unavailable', 'bad');
    } else {
      paneStatus(camStatus, 'connecting…', 'amber');
      camImg.onload = () => paneStatus(camStatus, 'live', 'live');
      camImg.onerror = () =>
        paneStatus(camStatus, camHint || 'unavailable', 'bad');
      camImg.src = api.url('/api/preview/camera.mjpeg');
    }
  }

  button?.addEventListener('click', () => {
    if (button.disabled) return;
    openModal();
  });

  return {
    updateFromStatus(status) {
      setButtonState(status?.preview);
    },
    close,
  };
}
