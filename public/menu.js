initPageAuth()
  .then((user) => {
    if (user.role === "admin") {
      document.getElementById("menu-users-link").classList.remove("hidden");
    }
  })
  .catch(() => {});
