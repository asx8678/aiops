const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
  params: {_csrf_token: csrfToken}
});
liveSocket.connect();
