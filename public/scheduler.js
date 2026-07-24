const form = document.getElementById("schedule-form");
const statusEl = document.getElementById("form-status");
const listEl = document.getElementById("schedule-list");
const emptyEl = document.getElementById("empty-state");
const historyListEl = document.getElementById("history-list");
const historyEmptyEl = document.getElementById("history-empty");
const refreshBtn = document.getElementById("refresh-btn");
const refreshHistoryBtn = document.getElementById("refresh-history-btn");
const runNowBtn = document.getElementById("run-now-btn");
const batPathInput = document.getElementById("bat-path");
const dateInput = document.getElementById("run-date");
const timeInput = document.getElementById("run-time");

function setDefaultDateTime() {
  const now = new Date();
  now.setMinutes(now.getMinutes() + 5);
  const yyyy = now.getFullYear();
  const mm = String(now.getMonth() + 1).padStart(2, "0");
  const dd = String(now.getDate()).padStart(2, "0");
  const hh = String(now.getHours()).padStart(2, "0");
  const mi = String(now.getMinutes()).padStart(2, "0");
  dateInput.value = `${yyyy}-${mm}-${dd}`;
  timeInput.value = `${hh}:${mi}`;
}

function setStatus(message, type) {
  statusEl.textContent = localize(message);
  statusEl.className = `status${type ? ` ${type}` : ""}`;
}

function formatSchedule(item) {
  const when = item.daily ? `每天 ${item.time}` : `${item.date} ${item.time}`;
  return { when, path: item.batPath, name: item.displayName || item.taskName };
}

function formatSource(source) {
  const map = {
    manual: "立刻執行",
    "schedule-run": "排程（手動觸發）",
    scheduled: "排程（自動）",
  };
  return map[source] || source || "未知";
}

function formatDuration(ms) {
  if (ms == null || ms < 0) return "";
  if (ms < 1000) return `${ms} ms`;
  return `${(ms / 1000).toFixed(2)} 秒`;
}

function runResultMessage(run) {
  if (!run) return "執行完成";
  if (run.success) {
    return `執行成功${run.durationMs != null ? `（${formatDuration(run.durationMs)}）` : ""}`;
  }
  const detail = run.message ? `：${localize(run.message)}` : "";
  return `執行失敗${detail}`;
}

async function runBatNow(batPath) {
  const res = await apiFetch("/api/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ batPath: batPath.trim() }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || "執行失敗");
  return data;
}

async function loadExecutions() {
  const res = await apiFetch("/api/executions?limit=50");
  if (!res.ok) throw new Error("無法載入執行紀錄");
  const data = await res.json();
  historyListEl.innerHTML = "";

  if (!data.items || data.items.length === 0) {
    historyEmptyEl.classList.remove("hidden");
    return;
  }

  historyEmptyEl.classList.add("hidden");

  for (const item of data.items) {
    const li = document.createElement("li");
    const badgeClass = item.success ? "ok" : "fail";
    const badgeText = item.success ? "成功" : "失敗";
    const title = item.displayName || formatSource(item.source);
    const detailParts = [formatSource(item.source), item.batPath];
    if (!item.success && item.message) {
      detailParts.push(localize(item.message));
    } else if (item.exitCode != null && item.exitCode !== 0) {
      detailParts.push(`結束代碼 ${item.exitCode}`);
    }
    if (item.durationMs != null) detailParts.push(formatDuration(item.durationMs));

    li.innerHTML = `
      <span class="badge ${badgeClass}">${badgeText}</span>
      <div class="history-main">
        <p class="history-title">${escapeHtml(title)}</p>
        <p class="history-meta">${escapeHtml(detailParts.join(" · "))}</p>
      </div>
      <p class="history-time">${escapeHtml(formatDateTime(item.finishedAt || item.startedAt))}</p>
    `;
    historyListEl.appendChild(li);
  }
}

async function loadSchedules() {
  const res = await apiFetch("/api/schedules");
  if (!res.ok) throw new Error("無法載入排程列表");
  const data = await res.json();
  listEl.innerHTML = "";

  if (!data.items || data.items.length === 0) {
    emptyEl.classList.remove("hidden");
    emptyEl.textContent = "尚無排程。建立後會顯示在這裡。";
    return;
  }

  emptyEl.classList.add("hidden");

  for (const item of data.items) {
    const { when, path, name } = formatSchedule(item);
    const li = document.createElement("li");
    li.innerHTML = `
      <div>
        <p class="item-title">${escapeHtml(name)}</p>
        <p class="item-meta">${escapeHtml(when)} · ${escapeHtml(path)}</p>
      </div>
      <div class="item-actions">
        <button type="button" class="ghost" data-action="run" data-id="${escapeAttr(item.id)}">立刻執行</button>
        <button type="button" class="danger" data-action="delete" data-id="${escapeAttr(item.id)}">刪除</button>
      </div>
    `;
    listEl.appendChild(li);
  }
}

runNowBtn.addEventListener("click", async () => {
  const batPath = batPathInput.value.trim();
  if (!batPath) {
    setStatus("請輸入 bat 檔路徑", "err");
    batPathInput.focus();
    return;
  }

  setStatus("執行中…");
  runNowBtn.disabled = true;
  try {
    const data = await runBatNow(batPath);
    const ok = data.run && data.run.success;
    setStatus(runResultMessage(data.run), ok ? "ok" : "err");
    await loadExecutions();
  } catch (err) {
    setStatus(err.message || "執行失敗", "err");
  } finally {
    runNowBtn.disabled = false;
  }
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  setStatus("建立中…");

  const payload = {
    batPath: document.getElementById("bat-path").value.trim(),
    date: dateInput.value,
    time: timeInput.value,
    daily: document.getElementById("daily").checked,
    taskName: document.getElementById("task-name").value.trim(),
  };

  try {
    const res = await apiFetch("/api/schedules", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "建立失敗");
    setStatus(`已建立：${data.item.displayName || data.item.taskName}`, "ok");
    form.reset();
    setDefaultDateTime();
    await loadSchedules();
  } catch (err) {
    setStatus(err.message || "建立失敗", "err");
  }
});

listEl.addEventListener("click", async (event) => {
  const btn = event.target.closest("button[data-action]");
  if (!btn) return;

  const action = btn.getAttribute("data-action");
  const id = btn.getAttribute("data-id");

  if (action === "run") {
    setStatus("執行中…");
    btn.disabled = true;
    try {
      const res = await apiFetch(`/api/schedules/${encodeURIComponent(id)}/run`, { method: "POST" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "執行失敗");
      const ok = data.run && data.run.success;
      setStatus(runResultMessage(data.run), ok ? "ok" : "err");
      await loadExecutions();
    } catch (err) {
      setStatus(err.message || "執行失敗", "err");
    } finally {
      btn.disabled = false;
    }
    return;
  }

  if (action !== "delete") return;
  if (!confirm("確定要刪除此排程嗎？")) return;

  try {
    const res = await apiFetch(`/api/schedules/${encodeURIComponent(id)}`, { method: "DELETE" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "刪除失敗");
    setStatus("已刪除排程", "ok");
    await loadSchedules();
  } catch (err) {
    setStatus(err.message || "刪除失敗", "err");
  }
});

refreshBtn.addEventListener("click", async () => {
  try {
    await loadSchedules();
    setStatus("已重新整理排程", "ok");
  } catch (err) {
    setStatus(err.message || "重新整理失敗", "err");
  }
});

refreshHistoryBtn.addEventListener("click", async () => {
  try {
    await loadExecutions();
    setStatus("已重新整理執行紀錄", "ok");
  } catch (err) {
    setStatus(err.message || "重新整理失敗", "err");
  }
});

setDefaultDateTime();
renderBackToMenu();
initPageAuth()
  .then(() => Promise.all([loadSchedules(), loadExecutions()]))
  .catch((err) => setStatus(err.message || "載入失敗", "err"));
