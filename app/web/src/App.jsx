import { useEffect, useState } from "react";

const API_URL = import.meta.env.VITE_API_URL || "http://localhost:8000";
const TOKEN_KEY = "events_auth_token";
const USER_KEY = "events_auth_user";

export default function App() {
  function loadStoredUser() {
    const raw = localStorage.getItem(USER_KEY);
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      localStorage.removeItem(USER_KEY);
      return null;
    }
  }

  const [token, setToken] = useState(() => localStorage.getItem(TOKEN_KEY) || "");
  const [currentUser, setCurrentUser] = useState(loadStoredUser);
  const [events, setEvents] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [loginForm, setLoginForm] = useState({
    identifier: "admin@example.com",
    password: "admin123",
  });
  const [loginError, setLoginError] = useState("");
  const [loginLoading, setLoginLoading] = useState(false);
  const [registerForm, setRegisterForm] = useState({
    username: "",
    email: "",
    password: "",
  });
  const [registerError, setRegisterError] = useState("");
  const [registerLoading, setRegisterLoading] = useState(false);
  const [form, setForm] = useState({
    title: "",
    manual_description: "",
    country: "Spain",
    language: "es",
  });

  async function apiFetch(path, options = {}) {
    const headers = {
      ...(options.headers || {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    };
    return fetch(`${API_URL}${path}`, { ...options, headers });
  }

  async function loadEvents() {
    if (!token) {
      setEvents([]);
      setLoading(false);
      return;
    }

    setLoading(true);
    setError("");
    try {
      const res = await apiFetch("/events");
      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (!res.ok) throw new Error(`Error ${res.status}`);
      const data = await res.json();
      setEvents(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadEvents();
  }, [token]);

  async function onLogin(e) {
    e.preventDefault();
    setLoginError("");
    setLoginLoading(true);

    try {
      const res = await fetch(`${API_URL}/auth/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(loginForm),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || `Error ${res.status}`);

      setToken(data.access_token);
      setCurrentUser(data.user);
      localStorage.setItem(TOKEN_KEY, data.access_token);
      localStorage.setItem(USER_KEY, JSON.stringify(data.user));
    } catch (err) {
      setLoginError(err.message);
    } finally {
      setLoginLoading(false);
    }
  }

  async function onRegister(e) {
    e.preventDefault();
    setRegisterError("");
    setRegisterLoading(true);

    try {
      const res = await fetch(`${API_URL}/auth/register`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(registerForm),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || `Error ${res.status}`);

      setToken(data.access_token);
      setCurrentUser(data.user);
      localStorage.setItem(TOKEN_KEY, data.access_token);
      localStorage.setItem(USER_KEY, JSON.stringify(data.user));
      setRegisterForm({ username: "", email: "", password: "" });
    } catch (err) {
      setRegisterError(err.message);
    } finally {
      setRegisterLoading(false);
    }
  }

  function logout() {
    setToken("");
    setCurrentUser(null);
    setEvents([]);
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(USER_KEY);
  }

  async function onSubmit(e) {
    e.preventDefault();
    setError("");
    try {
      const res = await apiFetch("/events", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (!res.ok) throw new Error(`Error ${res.status}`);
      setForm({ title: "", manual_description: "", country: "Spain", language: "es" });
      await loadEvents();
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <main className="container">
      <h1>Events App</h1>
      <p>Base local: React + FastAPI + PostgreSQL + batch svc.</p>

      {!token && (
        <>
          <section className="card">
            <h2>Login</h2>
            <p>
              Usuario demo: <code>admin@example.com</code> / <code>admin123</code>
            </p>
            <form onSubmit={onLogin} className="form">
              <input
                required
                placeholder="Email o username"
                value={loginForm.identifier}
                onChange={(e) => setLoginForm((prev) => ({ ...prev, identifier: e.target.value }))}
              />
              <input
                required
                type="password"
                placeholder="Contrasena"
                value={loginForm.password}
                onChange={(e) => setLoginForm((prev) => ({ ...prev, password: e.target.value }))}
              />
              <button type="submit" disabled={loginLoading}>
                {loginLoading ? "Entrando..." : "Entrar"}
              </button>
            </form>
            {loginError && <p className="error">{loginError}</p>}
          </section>

          <section className="card">
            <h2>Registro</h2>
            <form onSubmit={onRegister} className="form">
              <input
                required
                placeholder="Username"
                value={registerForm.username}
                onChange={(e) => setRegisterForm((prev) => ({ ...prev, username: e.target.value }))}
              />
              <input
                required
                type="email"
                placeholder="Email"
                value={registerForm.email}
                onChange={(e) => setRegisterForm((prev) => ({ ...prev, email: e.target.value }))}
              />
              <input
                required
                type="password"
                placeholder="Contrasena (min 6)"
                value={registerForm.password}
                onChange={(e) => setRegisterForm((prev) => ({ ...prev, password: e.target.value }))}
              />
              <button type="submit" disabled={registerLoading}>
                {registerLoading ? "Creando..." : "Crear usuario"}
              </button>
            </form>
            {registerError && <p className="error">{registerError}</p>}
          </section>
        </>
      )}

      {token && (
        <section className="card">
          <h2>Sesion</h2>
          <p>
            Conectado como <strong>{currentUser?.username}</strong> ({currentUser?.role})
          </p>
          <button type="button" onClick={logout}>
            Cerrar sesion
          </button>
        </section>
      )}

      {token && (
        <>
          <section className="card">
            <h2>Nuevo evento</h2>
            <form onSubmit={onSubmit} className="form">
              <input
                required
                placeholder="Titulo"
                value={form.title}
                onChange={(e) => setForm((prev) => ({ ...prev, title: e.target.value }))}
              />
              <textarea
                placeholder="Descripcion"
                value={form.manual_description}
                onChange={(e) =>
                  setForm((prev) => ({ ...prev, manual_description: e.target.value }))
                }
              />
              <input
                placeholder="Pais"
                value={form.country}
                onChange={(e) => setForm((prev) => ({ ...prev, country: e.target.value }))}
              />
              <input
                placeholder="Idioma"
                value={form.language}
                onChange={(e) => setForm((prev) => ({ ...prev, language: e.target.value }))}
              />
              <button type="submit">Crear</button>
            </form>
          </section>

          <section className="card">
            <h2>Eventos</h2>
            {loading && <p>Cargando...</p>}
            {error && <p className="error">{error}</p>}
            {!loading && !events.length && <p>No hay eventos todavia.</p>}
            <ul className="events">
              {events.map((event) => (
                <li key={event.id}>
                  <strong>{event.title}</strong>
                  <span>{event.country || "-"}</span>
                  <span>{event.status}</span>
                </li>
              ))}
            </ul>
          </section>
        </>
      )}
    </main>
  );
}
