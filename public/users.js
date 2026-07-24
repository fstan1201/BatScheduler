const usersListEl = document.getElementById("users-list");
const usersEmptyEl = document.getElementById("users-empty");
const userForm = document.getElementById("user-form");
const userFormStatusEl = document.getElementById("user-form-status");
const refreshUsersBtn = document.getElementById("refresh-users-btn");

let currentUser = null;

function setUserFormStatus(message, type) {
  userFormStatusEl.textContent = localize(message);
  userFormStatusEl.className = `status${type ? ` ${type}` : ""}`;
}

async function loadUsers() {
  const res = await apiFetch("/api/users");
  if (!res.ok) throw new Error("無法載入使用者列表");
  const data = await res.json();
  usersListEl.innerHTML = "";

  if (!data.items || data.items.length === 0) {
    usersEmptyEl.classList.remove("hidden");
    return;
  }

  usersEmptyEl.classList.add("hidden");

  for (const user of data.items) {
    const li = document.createElement("li");
    li.innerHTML = `
      <div>
        <p class="item-title">${escapeHtml(user.username)}</p>
        <p class="item-meta">${escapeHtml(formatRole(user.role))} · 建立於 ${escapeHtml(formatDateTime(user.createdAt))}</p>
        <div class="inline-edit">
          <input type="password" placeholder="新密碼（留空則不變更）" data-user-password="${escapeAttr(user.username)}" autocomplete="new-password" />
          <select data-user-role="${escapeAttr(user.username)}">
            <option value="user"${user.role === "user" ? " selected" : ""}>一般使用者</option>
            <option value="admin"${user.role === "admin" ? " selected" : ""}>管理者</option>
          </select>
        </div>
      </div>
      <div class="user-actions">
        <button type="button" class="ghost" data-user-action="save" data-username="${escapeAttr(user.username)}">儲存變更</button>
        <button type="button" class="danger" data-user-action="delete" data-username="${escapeAttr(user.username)}">刪除</button>
      </div>
    `;
    usersListEl.appendChild(li);
  }
}

userForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  setUserFormStatus("建立中…");

  const payload = {
    username: document.getElementById("new-username").value.trim(),
    password: document.getElementById("new-password").value,
    role: document.getElementById("new-role").value,
  };

  try {
    const res = await apiFetch("/api/users", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "建立使用者失敗");
    setUserFormStatus(`已新增：${data.user.username}`, "ok");
    userForm.reset();
    await loadUsers();
  } catch (err) {
    setUserFormStatus(err.message || "建立使用者失敗", "err");
  }
});

usersListEl.addEventListener("click", async (event) => {
  const btn = event.target.closest("button[data-user-action]");
  if (!btn) return;

  const action = btn.getAttribute("data-user-action");
  const username = btn.getAttribute("data-username");
  if (!username) return;

  if (action === "delete") {
    if (!confirm(`確定要刪除使用者「${username}」嗎？`)) return;
    try {
      const res = await apiFetch(`/api/users/${encodeURIComponent(username)}`, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "刪除失敗");
      setUserFormStatus(`已刪除：${username}`, "ok");
      await loadUsers();
    } catch (err) {
      setUserFormStatus(err.message || "刪除失敗", "err");
    }
    return;
  }

  if (action !== "save") return;

  const passwordInput = usersListEl.querySelector(`input[data-user-password="${CSS.escape(username)}"]`);
  const roleSelect = usersListEl.querySelector(`select[data-user-role="${CSS.escape(username)}"]`);
  const payload = { role: roleSelect ? roleSelect.value : undefined };
  if (passwordInput && passwordInput.value) payload.password = passwordInput.value;

  if (!payload.password && !payload.role) {
    setUserFormStatus("請輸入新密碼或選擇角色", "err");
    return;
  }

  try {
    const res = await apiFetch(`/api/users/${encodeURIComponent(username)}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || "更新失敗");
    if (passwordInput) passwordInput.value = "";
    setUserFormStatus(`已更新：${username}`, "ok");
    await loadUsers();
    if (currentUser && currentUser.username === username && payload.role) {
      document.getElementById("current-role").textContent = formatRole(payload.role);
    }
  } catch (err) {
    setUserFormStatus(err.message || "更新失敗", "err");
  }
});

refreshUsersBtn.addEventListener("click", async () => {
  try {
    await loadUsers();
    setUserFormStatus("已重新整理使用者列表", "ok");
  } catch (err) {
    setUserFormStatus(err.message || "重新整理失敗", "err");
  }
});

renderBackToMenu();
initPageAuth({ requireAdmin: true })
  .then((user) => {
    currentUser = user;
    return loadUsers();
  })
  .catch((err) => setUserFormStatus(err.message || "載入失敗", "err"));
