async function apiFetch(url, options = {}) {
  const res = await fetch(url, {
    credentials: "same-origin",
    ...options,
  });
  if (res.status === 401) {
    window.location.href = "/login.html";
    throw new Error("Unauthorized");
  }
  return res;
}

function localize(message) {
  const text = String(message || "");
  const map = [
    [/Please enter a bat file path/i, "請輸入 bat 檔路徑"],
    [/Path contains invalid characters/i, "路徑含有不允許的字元"],
    [/File not found:/i, "找不到檔案："],
    [/Only \.bat files are allowed/i, "只接受 .bat 檔案"],
    [/Invalid date format/i, "日期格式錯誤"],
    [/Invalid time format/i, "時間格式錯誤"],
    [/Scheduled time must be in the future/i, "執行時間必須晚於現在"],
    [/Failed to create scheduled task:/i, "無法建立系統排程："],
    [/Failed to delete scheduled task:/i, "無法刪除系統排程："],
    [/Schedule not found/i, "找不到此排程"],
    [/Missing request body/i, "缺少請求內容"],
    [/Failed to run bat:/i, "無法執行 bat："],
    [/Exit code/i, "結束代碼"],
    [/Unauthorized/i, "未登入"],
    [/Admin only/i, "僅管理者可使用"],
    [/Forbidden/i, "沒有權限"],
    [/Username already exists/i, "帳號已存在"],
    [/Invalid username or password/i, "帳號或密碼錯誤"],
    [/Password must be at least 4 characters/i, "密碼至少 4 個字元"],
    [/Cannot delete the last admin/i, "無法刪除最後一位管理者"],
    [/Cannot delete your own account while logged in/i, "無法刪除目前登入中的帳號"],
  ];
  let out = text;
  for (const [pattern, zh] of map) {
    out = out.replace(pattern, zh);
  }
  return out;
}

function formatRole(role) {
  return role === "admin" ? "管理者" : "一般使用者";
}

function formatDateTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString("zh-TW", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("'", "&#39;");
}

async function fetchCurrentUser() {
  const res = await apiFetch("/api/auth/me");
  const data = await res.json();
  return data.user;
}

function renderTopbar(user) {
  const userEl = document.getElementById("current-user");
  const roleEl = document.getElementById("current-role");
  if (userEl) userEl.textContent = user.username;
  if (roleEl) roleEl.textContent = formatRole(user.role);
}

function bindLogout() {
  const logoutBtn = document.getElementById("logout-btn");
  if (!logoutBtn) return;
  logoutBtn.addEventListener("click", async () => {
    try {
      await apiFetch("/api/auth/logout", { method: "POST" });
    } catch {
      // still redirect
    }
    window.location.href = "/login.html";
  });
}

async function initPageAuth(options = {}) {
  const { requireAdmin = false } = options;
  const user = await fetchCurrentUser();
  renderTopbar(user);
  bindLogout();

  if (requireAdmin && user.role !== "admin") {
    window.location.href = "/menu.html";
    throw new Error("Forbidden");
  }
  return user;
}

function renderBackToMenu() {
  const slot = document.getElementById("nav-back");
  if (!slot) return;
  slot.innerHTML = `<a class="ghost nav-back" href="/menu.html">← 返回主選單</a>`;
}
