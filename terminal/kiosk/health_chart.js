/* global document, window */
(function (global) {
  /**
   * Compact dual-series area sparkline (CPU orange, memory purple).
   */
  class HealthChart {
    constructor(canvas, { maxPoints = 60 } = {}) {
      this.canvas = canvas;
      this.ctx = canvas.getContext('2d');
      this.maxPoints = maxPoints;
      this.points = []; // { cpu, mem, ts }
      this._resize();
      window.addEventListener('resize', () => this._resize());
    }

    _resize() {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const cssW = this.canvas.clientWidth || 168;
      const cssH = this.canvas.clientHeight || 56;
      this.canvas.width = Math.round(cssW * dpr);
      this.canvas.height = Math.round(cssH * dpr);
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      this.w = cssW;
      this.h = cssH;
      this.draw();
    }

    push(cpu, mem, ts) {
      this.points.push({
        cpu: Number(cpu) || 0,
        mem: Number(mem) || 0,
        ts: ts || Date.now(),
      });
      if (this.points.length > this.maxPoints) {
        this.points.splice(0, this.points.length - this.maxPoints);
      }
      this.draw();
    }

    _fmtTime(ts) {
      const d = new Date(ts);
      let h = d.getHours();
      const m = d.getMinutes().toString().padStart(2, '0');
      const ampm = h >= 12 ? 'PM' : 'AM';
      h = h % 12;
      if (h === 0) h = 12;
      return `${h}:${m} ${ampm}`;
    }

    _smoothPath(ctx, pts) {
      if (pts.length === 0) return;
      ctx.moveTo(pts[0].x, pts[0].y);
      if (pts.length === 1) return;
      for (let i = 1; i < pts.length - 1; i++) {
        const midX = (pts[i].x + pts[i + 1].x) / 2;
        const midY = (pts[i].y + pts[i + 1].y) / 2;
        ctx.quadraticCurveTo(pts[i].x, pts[i].y, midX, midY);
      }
      ctx.lineTo(pts[pts.length - 1].x, pts[pts.length - 1].y);
    }

    draw() {
      const ctx = this.ctx;
      const w = this.w;
      const h = this.h;
      if (!ctx || !w || !h) return;

      const padL = 2;
      const padR = 2;
      const padT = 4;
      const padB = 14;
      const plotW = w - padL - padR;
      const plotH = h - padT - padB;

      ctx.clearRect(0, 0, w, h);

      // Subtle backdrop matching kiosk night palette.
      ctx.fillStyle = 'rgba(8, 12, 18, 0.55)';
      ctx.beginPath();
      const r = 6;
      ctx.moveTo(r, 0);
      ctx.arcTo(w, 0, w, h, r);
      ctx.arcTo(w, h, 0, h, r);
      ctx.arcTo(0, h, 0, 0, r);
      ctx.arcTo(0, 0, w, 0, r);
      ctx.closePath();
      ctx.fill();

      if (this.points.length < 1) return;

      const n = this.points.length;
      const toPts = (key) =>
        this.points.map((p, i) => ({
          x: padL + (n === 1 ? plotW : (i / (n - 1)) * plotW),
          y: padT + plotH * (1 - Math.min(100, Math.max(0, p[key])) / 100),
        }));

      const cpuPts = toPts('cpu');
      const memPts = toPts('mem');
      const baseY = padT + plotH;

      const fillSeries = (pts, topColor, bottomColor) => {
        if (pts.length === 0) return;
        const grad = ctx.createLinearGradient(0, padT, 0, baseY);
        grad.addColorStop(0, topColor);
        grad.addColorStop(1, bottomColor);
        ctx.beginPath();
        this._smoothPath(ctx, pts);
        ctx.lineTo(pts[pts.length - 1].x, baseY);
        ctx.lineTo(pts[0].x, baseY);
        ctx.closePath();
        ctx.fillStyle = grad;
        ctx.fill();
      };

      const strokeSeries = (pts, color) => {
        if (pts.length === 0) return;
        ctx.beginPath();
        this._smoothPath(ctx, pts);
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.lineJoin = 'round';
        ctx.lineCap = 'round';
        ctx.stroke();
      };

      // CPU (orange) under, memory (purple) over — matches reference.
      fillSeries(cpuPts, 'rgba(249, 115, 22, 0.35)', 'rgba(249, 115, 22, 0.02)');
      fillSeries(memPts, 'rgba(168, 85, 247, 0.40)', 'rgba(168, 85, 247, 0.02)');
      strokeSeries(cpuPts, '#fb923c');
      strokeSeries(memPts, '#c084fc');

      // Time labels: start / end.
      ctx.fillStyle = 'rgba(226, 232, 240, 0.55)';
      ctx.font = '9px ui-sans-serif, system-ui, sans-serif';
      ctx.textBaseline = 'top';
      const first = this.points[0];
      const last = this.points[n - 1];
      ctx.textAlign = 'left';
      ctx.fillText(this._fmtTime(first.ts), padL, h - 11);
      if (n > 1) {
        ctx.textAlign = 'right';
        ctx.fillText(this._fmtTime(last.ts), w - padR, h - 11);
      }

      // Tiny legend values.
      const latest = last;
      ctx.textAlign = 'right';
      ctx.textBaseline = 'top';
      ctx.font = '8px ui-sans-serif, system-ui, sans-serif';
      ctx.fillStyle = '#fb923c';
      ctx.fillText(`CPU ${latest.cpu.toFixed(0)}%`, w - padR, 3);
      ctx.fillStyle = '#c084fc';
      ctx.fillText(`MEM ${latest.mem.toFixed(0)}%`, w - padR, 13);
    }
  }

  global.ComstarHealthChart = HealthChart;
})(typeof window !== 'undefined' ? window : globalThis);
