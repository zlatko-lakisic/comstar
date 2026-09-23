/** Admin Live view — wayvnc panel (noVNC) + camera MJPEG + vision boxes. */

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

/** Map object-fit:contain letterbox so pixel boxes align with the JPEG. */
function containRect(frameW, frameH, naturalW, naturalH) {
  if (!frameW || !frameH || !naturalW || !naturalH) {
    return { x: 0, y: 0, w: frameW, h: frameH, scale: 1 };
  }
  const scale = Math.min(frameW / naturalW, frameH / naturalH);
  const w = naturalW * scale;
  const h = naturalH * scale;
  return {
    x: (frameW - w) / 2,
    y: (frameH - h) / 2,
    w,
    h,
    scale,
  };
}

function drawVisionOverlays(canvas, img, overlays) {
  if (!canvas || !img) return;
  const parent = canvas.parentElement;
  const cw = parent?.clientWidth || img.clientWidth || 0;
  const ch = parent?.clientHeight || img.clientHeight || 0;
  if (!cw || !ch) return;

  const dpr = window.devicePixelRatio || 1;
  if (canvas.width !== Math.round(cw * dpr) || canvas.height !== Math.round(ch * dpr)) {
    canvas.width = Math.round(cw * dpr);
    canvas.height = Math.round(ch * dpr);
    canvas.style.width = `${cw}px`;
    canvas.style.height = `${ch}px`;
  }

  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cw, ch);

  const nw = img.naturalWidth || 0;
  const nh = img.naturalHeight || 0;
  if (!nw || !nh || !overlays?.length) return;

  const box = containRect(cw, ch, nw, nh);
  for (const o of overlays) {
    const x = box.x + o.x_min * box.scale;
    const y = box.y + o.y_min * box.scale;
    const w = (o.x_max - o.x_min) * box.scale;
    const h = (o.y_max - o.y_min) * box.scale;
    if (w <= 0 || h <= 0) continue;

    const known = o.label && o.label !== 'unknown';
    const stroke = known ? '#3dffa8' : '#ffb020';
    ctx.strokeStyle = stroke;
    ctx.lineWidth = 2;
    ctx.strokeRect(x, y, w, h);

    const conf = typeof o.confidence === 'number'
      ? ` ${(o.confidence * 100).toFixed(0)}%`
      : '';
    const text = `${o.label || 'unknown'}${conf}`;
    ctx.font = '600 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
    const tw = ctx.measureText(text).width + 8;
    const th = 16;
    const ty = Math.max(0, y - th);
    ctx.fillStyle = 'rgba(0,0,0,0.65)';
    ctx.fillRect(x, ty, tw, th);
    ctx.fillStyle = stroke;
    ctx.fillText(text, x + 4, ty + 12);
  }
}

export function createLivePreview({ api, modalRoot, button }) {
  let open = false;
  let onKey = null;
  let rfb = null;
  let visionTimer = null;
  let onVisionResize = null;

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
    if (visionTimer) {
      clearInterval(visionTimer);
      visionTimer = null;
    }
    if (onVisionResize) {
      window.removeEventListener('resize', onVisionResize);
      onVisionResize = null;
    }
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
    const overlay = modalRoot.querySelector('#previewCameraOverlay');
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
    if (overlay) {
      const ctx = overlay.getContext?.('2d');
      if (ctx) {
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, overlay.width, overlay.height);
      }
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

  function startVisionOverlay(camImg, canvas) {
    let lastOverlays = [];
    const redraw = () => drawVisionOverlays(canvas, camImg, lastOverlays);

    const poll = async () => {
      if (!open) return;
      try {
        const data = await api.get('/api/preview/vision');
        lastOverlays = Array.isArray(data?.overlays) ? data.overlays : [];
        redraw();
      } catch (_) {
        // keep last boxes; stream may still be fine
      }
    };

    onVisionResize = redraw;
    window.addEventListener('resize', onVisionResize);
    visionTimer = setInterval(poll, 400);
    poll();
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
                <canvas id="previewCameraOverlay" class="preview-pane__overlay" aria-hidden="true"></canvas>
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
    const camOverlay = modalRoot.querySelector('#previewCameraOverlay');

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
      camImg.onload = () => {
        paneStatus(camStatus, 'live', 'live');
        drawVisionOverlays(camOverlay, camImg, []);
      };
      camImg.onerror = () =>
        paneStatus(camStatus, camHint || 'unavailable', 'bad');
      camImg.src = api.url('/api/preview/camera.mjpeg');
      startVisionOverlay(camImg, camOverlay);
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
