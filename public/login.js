const form = document.getElementById("login-form");
const statusEl = document.getElementById("login-status");

function setStatus(message, type) {
  statusEl.textContent = message;
  statusEl.className = `status${type ? ` ${type}` : ""}`;
}

async function checkAlreadyLoggedIn() {
  const res = await fetch("/api/auth/me", { credentials: "same-origin" });
  if (res.ok) {
    window.location.href = "/menu.html";
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  setStatus("登入中…");

  const payload = {
    username: document.getElementById("username").value.trim(),
    password: document.getElementById("password").value,
  };

  try {
    const res = await fetch("/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.error || "登入失敗");
    }
    window.location.href = "/menu.html";
  } catch (err) {
    const msg = String(err.message || "登入失敗");
    if (/Invalid username or password/i.test(msg)) {
      setStatus("帳號或密碼錯誤", "err");
    } else {
      setStatus(msg, "err");
    }
  }
});

checkAlreadyLoggedIn();
