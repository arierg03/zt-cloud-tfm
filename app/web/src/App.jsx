import { useEffect, useMemo, useRef, useState } from "react";

const API_URL = import.meta.env.VITE_API_URL || "http://localhost:8000";
const TOKEN_KEY = "events_auth_token";
const USER_KEY = "events_auth_user";
const WEEKDAYS = ["L", "M", "X", "J", "V", "S", "D"];

function parseRouteFromHash(hashValue) {
  const hash = (hashValue || "").replace(/^#/, "") || "/";
  const detailMatch = hash.match(/^\/events\/(\d+)$/);
  if (detailMatch) {
    return { name: "detail", eventId: Number(detailMatch[1]) };
  }
  return { name: "home", eventId: null };
}

function toDateInputValue(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function buildCalendarCells(monthDate) {
  const year = monthDate.getFullYear();
  const month = monthDate.getMonth();
  const firstDay = new Date(year, month, 1);
  const startOffset = (firstDay.getDay() + 6) % 7;
  const startDate = new Date(year, month, 1 - startOffset);

  return Array.from({ length: 42 }, (_, index) => {
    const dayDate = new Date(startDate);
    dayDate.setDate(startDate.getDate() + index);
    return {
      key: toDateInputValue(dayDate),
      value: toDateInputValue(dayDate),
      day: dayDate.getDate(),
      isCurrentMonth: dayDate.getMonth() === month,
      isToday: toDateInputValue(dayDate) === toDateInputValue(new Date()),
    };
  });
}

function formatEventDateTime(value) {
  if (!value) return "Sin fecha";
  const date = new Date(value);
  return new Intl.DateTimeFormat("es-ES", {
    dateStyle: "full",
    timeStyle: "short",
  }).format(date);
}

function toTimeInputValue(date) {
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${hours}:${minutes}`;
}

function eventToForm(event) {
  if (!event) {
    return {
      title: "",
      manual_description: "",
      event_date: "",
      event_time: "19:00",
      country: "Spain",
      language: "es",
    };
  }

  if (!event.event_date) {
    return {
      title: event.title || "",
      manual_description: event.manual_description || "",
      event_date: "",
      event_time: "19:00",
      country: event.country || "",
      language: event.language || "es",
    };
  }

  const date = new Date(event.event_date);
  return {
    title: event.title || "",
    manual_description: event.manual_description || "",
    event_date: toDateInputValue(date),
    event_time: toTimeInputValue(date),
    country: event.country || "",
    language: event.language || "es",
  };
}

function buildEventPayload(form) {
  const payload = {
    title: form.title.trim(),
    manual_description: form.manual_description.trim() || null,
    country: form.country.trim() || null,
    language: form.language.trim() || null,
    event_date: null,
  };

  if (form.event_date) {
    payload.event_date = `${form.event_date}T${form.event_time || "00:00"}:00`;
  }

  return payload;
}

function CalendarPicker({ value, onChange }) {
  const [open, setOpen] = useState(false);
  const [monthCursor, setMonthCursor] = useState(() => {
    if (value) return new Date(`${value}T00:00:00`);
    return new Date();
  });
  const wrapperRef = useRef(null);
  const calendarCells = useMemo(() => buildCalendarCells(monthCursor), [monthCursor]);

  useEffect(() => {
    if (!value) return;
    setMonthCursor(new Date(`${value}T00:00:00`));
  }, [value]);

  useEffect(() => {
    function handleOutsideClick(event) {
      if (wrapperRef.current && !wrapperRef.current.contains(event.target)) {
        setOpen(false);
      }
    }

    document.addEventListener("mousedown", handleOutsideClick);
    return () => document.removeEventListener("mousedown", handleOutsideClick);
  }, []);

  const monthTitle = new Intl.DateTimeFormat("es-ES", {
    month: "long",
    year: "numeric",
  }).format(monthCursor);

  const selectedLabel = value
    ? new Intl.DateTimeFormat("es-ES", { dateStyle: "full" }).format(new Date(`${value}T00:00:00`))
    : "Selecciona una fecha";

  return (
    <div className="calendar-picker" ref={wrapperRef}>
      <button
        type="button"
        className="calendar-trigger"
        aria-expanded={open}
        onClick={() => setOpen((prev) => !prev)}
      >
        <span>{selectedLabel}</span>
        <span className="calendar-trigger-icon">{open ? "^" : "v"}</span>
      </button>

      {open && (
        <div className="calendar-popover">
          <div className="calendar-header">
            <button
              type="button"
              className="calendar-nav"
              onClick={() =>
                setMonthCursor(
                  (prev) => new Date(prev.getFullYear(), prev.getMonth() - 1, 1)
                )
              }
            >
              {"<"}
            </button>
            <strong>{monthTitle}</strong>
            <button
              type="button"
              className="calendar-nav"
              onClick={() =>
                setMonthCursor(
                  (prev) => new Date(prev.getFullYear(), prev.getMonth() + 1, 1)
                )
              }
            >
              {">"}
            </button>
          </div>

          <div className="calendar-weekdays">
            {WEEKDAYS.map((day) => (
              <span key={day}>{day}</span>
            ))}
          </div>

          <div className="calendar-grid">
            {calendarCells.map((cell) => {
              const isSelected = value === cell.value;
              return (
                <button
                  key={cell.key}
                  type="button"
                  className={[
                    "calendar-day",
                    cell.isCurrentMonth ? "" : "calendar-day-muted",
                    cell.isToday ? "calendar-day-today" : "",
                    isSelected ? "calendar-day-selected" : "",
                  ]
                    .filter(Boolean)
                    .join(" ")}
                  onClick={() => {
                    onChange(cell.value);
                    setOpen(false);
                  }}
                >
                  {cell.day}
                </button>
              );
            })}
          </div>

          <div className="calendar-actions">
            <button
              type="button"
              onClick={() => {
                onChange(toDateInputValue(new Date()));
                setOpen(false);
              }}
            >
              Hoy
            </button>
            <button
              type="button"
              onClick={() => {
                onChange("");
                setOpen(false);
              }}
            >
              Limpiar
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

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
  const [route, setRoute] = useState(() => parseRouteFromHash(window.location.hash));
  const [registerError, setRegisterError] = useState("");
  const [registerLoading, setRegisterLoading] = useState(false);
  const [form, setForm] = useState({
    title: "",
    manual_description: "",
    event_date: "",
    event_time: "19:00",
    country: "Spain",
    language: "es",
  });
  const [detailEvent, setDetailEvent] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState("");
  const [editMode, setEditMode] = useState(false);
  const [editForm, setEditForm] = useState(eventToForm(null));
  const [updateLoading, setUpdateLoading] = useState(false);
  const [deleteLoading, setDeleteLoading] = useState(false);
  const [detailActionError, setDetailActionError] = useState("");
  const [detailActionMessage, setDetailActionMessage] = useState("");
  const [eventImages, setEventImages] = useState([]);
  const [imageLoading, setImageLoading] = useState(false);
  const [imageUploadLoading, setImageUploadLoading] = useState(false);
  const [imageError, setImageError] = useState("");
  const [selectedImageFile, setSelectedImageFile] = useState(null);
  const [selectedImagePreview, setSelectedImagePreview] = useState("");
  const [imageCaption, setImageCaption] = useState("");

  useEffect(() => {
    function onHashChange() {
      setRoute(parseRouteFromHash(window.location.hash));
    }

    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  }, []);

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
    const payload = buildEventPayload(form);

    try {
      const res = await apiFetch("/events", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (!res.ok) throw new Error(`Error ${res.status}`);
      setForm({
        title: "",
        manual_description: "",
        event_date: "",
        event_time: "19:00",
        country: "Spain",
        language: "es",
      });
      await loadEvents();
    } catch (err) {
      setError(err.message);
    }
  }

  async function loadEventDetail(eventId) {
    setDetailLoading(true);
    setDetailError("");
    setDetailActionError("");
    setDetailActionMessage("");
    setDetailEvent(null);
    try {
      const res = await apiFetch(`/events/${eventId}`);
      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (res.status === 404) throw new Error("Evento no encontrado");
      if (!res.ok) throw new Error(`Error ${res.status}`);
      const data = await res.json();
      setDetailEvent(data);
      setEditForm(eventToForm(data));
      await loadEventImages(eventId);
    } catch (err) {
      setDetailError(err.message);
    } finally {
      setDetailLoading(false);
    }
  }

  async function loadEventImages(eventId) {
    setImageLoading(true);
    setImageError("");
    try {
      const res = await apiFetch(`/events/${eventId}/images`);
      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (!res.ok) throw new Error(`Error ${res.status}`);
      const data = await res.json();
      setEventImages(Array.isArray(data) ? data : []);
      setImageCaption("");
    } catch (err) {
      setEventImages([]);
      setImageCaption("");
      setImageError(err.message);
    } finally {
      setImageLoading(false);
    }
  }

  useEffect(() => {
    if (!token) return;
    if (route.name !== "detail" || !route.eventId) return;
    loadEventDetail(route.eventId);
  }, [route, token]);

  useEffect(() => {
    if (route.name !== "detail") {
      setEditMode(false);
      setDetailActionError("");
      setDetailActionMessage("");
      setEventImages([]);
      setImageError("");
      setSelectedImageFile(null);
      setSelectedImagePreview("");
      setImageCaption("");
    }
  }, [route]);

  useEffect(() => {
    if (!selectedImageFile) {
      setSelectedImagePreview("");
      return;
    }
    const objectUrl = URL.createObjectURL(selectedImageFile);
    setSelectedImagePreview(objectUrl);
    return () => URL.revokeObjectURL(objectUrl);
  }, [selectedImageFile]);

  function goTo(path) {
    window.location.hash = path;
  }

  async function onUpdateEvent(e) {
    e.preventDefault();
    if (!route.eventId) return;

    setDetailActionError("");
    setDetailActionMessage("");
    setUpdateLoading(true);
    try {
      const res = await apiFetch(`/events/${route.eventId}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(buildEventPayload(editForm)),
      });

      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (res.status === 403) throw new Error("No tienes permisos para editar este evento.");
      if (res.status === 404) throw new Error("Evento no encontrado.");
      if (!res.ok) throw new Error(`Error ${res.status}`);

      const updated = await res.json();
      setDetailEvent(updated);
      setEditForm(eventToForm(updated));
      setEditMode(false);
      setDetailActionMessage("Evento actualizado.");
      await loadEvents();
    } catch (err) {
      setDetailActionError(err.message);
    } finally {
      setUpdateLoading(false);
    }
  }

  async function onDeleteEvent() {
    if (!route.eventId) return;
    const confirmed = window.confirm("Quieres eliminar este evento? Esta accion no se puede deshacer.");
    if (!confirmed) return;

    setDetailActionError("");
    setDetailActionMessage("");
    setDeleteLoading(true);
    try {
      const res = await apiFetch(`/events/${route.eventId}`, {
        method: "DELETE",
      });

      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (res.status === 403) throw new Error("No tienes permisos para eliminar este evento.");
      if (res.status === 404) throw new Error("Evento no encontrado.");
      if (!res.ok) throw new Error(`Error ${res.status}`);

      await loadEvents();
      goTo("/");
    } catch (err) {
      setDetailActionError(err.message);
    } finally {
      setDeleteLoading(false);
    }
  }

  async function onUploadImage(e) {
    e.preventDefault();
    if (!route.eventId || !selectedImageFile) return;

    setImageError("");
    setImageUploadLoading(true);
    try {
      const formData = new FormData();
      formData.append("file", selectedImageFile);
      if (imageCaption.trim()) formData.append("caption", imageCaption.trim());

      const res = await apiFetch(`/events/${route.eventId}/image`, {
        method: "POST",
        body: formData,
      });
      if (res.status === 401) {
        logout();
        throw new Error("Sesion expirada. Inicia sesion otra vez.");
      }
      if (res.status === 403) {
        throw new Error("Solo el creador del evento puede subir imagen.");
      }
      if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        throw new Error(errorData.detail || `Error ${res.status}`);
      }

      const data = await res.json();
      setEventImages((prev) => [data, ...prev]);
      setSelectedImageFile(null);
      setSelectedImagePreview("");
      setImageCaption(data.caption || "");
    } catch (err) {
      setImageError(err.message);
    } finally {
      setImageUploadLoading(false);
    }
  }

  const isImageUploader = Boolean(detailEvent && currentUser && detailEvent.created_by === currentUser.id);

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
              <label className="field-label">Fecha del evento</label>
              <CalendarPicker
                value={form.event_date}
                onChange={(newDate) => setForm((prev) => ({ ...prev, event_date: newDate }))}
              />
              <input
                type="time"
                value={form.event_time}
                onChange={(e) => setForm((prev) => ({ ...prev, event_time: e.target.value }))}
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

          {route.name === "home" && (
            <section className="card">
              <h2>Eventos</h2>
              {loading && <p>Cargando...</p>}
              {error && <p className="error">{error}</p>}
              {!loading && !events.length && <p>No hay eventos todavia.</p>}
              <ul className="events">
                {events.map((event) => (
                  <li key={event.id}>
                    <div className="event-main">
                      <strong>{event.title}</strong>
                      <span>{formatEventDateTime(event.event_date)}</span>
                    </div>
                    <span>{event.country || "-"}</span>
                    <span>{event.status}</span>
                    <button type="button" onClick={() => goTo(`/events/${event.id}`)}>
                      Ver detalle
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          )}

          {route.name === "detail" && (
            <section className="card event-detail">
              <div className="event-detail-header">
                <h2>Detalle del evento</h2>
                <button type="button" onClick={() => goTo("/")}>
                  Volver a la lista
                </button>
              </div>
              <div className="detail-actions">
                <button
                  type="button"
                  onClick={() => {
                    setEditMode((prev) => !prev);
                    setDetailActionError("");
                    setDetailActionMessage("");
                    if (!editMode) setEditForm(eventToForm(detailEvent));
                  }}
                  disabled={!detailEvent || detailLoading || deleteLoading}
                >
                  {editMode ? "Cancelar edicion" : "Editar evento"}
                </button>
                <button
                  type="button"
                  className="danger"
                  onClick={onDeleteEvent}
                  disabled={!detailEvent || detailLoading || deleteLoading || updateLoading}
                >
                  {deleteLoading ? "Eliminando..." : "Eliminar evento"}
                </button>
              </div>

              {detailLoading && <p>Cargando detalle...</p>}
              {detailError && <p className="error">{detailError}</p>}
              {detailActionError && <p className="error">{detailActionError}</p>}
              {detailActionMessage && <p className="success">{detailActionMessage}</p>}
              {!detailLoading && !detailError && detailEvent && (
                <dl className="event-detail-grid">
                  <div>
                    <dt>Titulo</dt>
                    <dd>{detailEvent.title}</dd>
                  </div>
                  <div>
                    <dt>Fecha</dt>
                    <dd>{formatEventDateTime(detailEvent.event_date)}</dd>
                  </div>
                  <div>
                    <dt>Pais</dt>
                    <dd>{detailEvent.country || "-"}</dd>
                  </div>
                  <div>
                    <dt>Idioma</dt>
                    <dd>{detailEvent.language || "-"}</dd>
                  </div>
                  <div>
                    <dt>Estado</dt>
                    <dd>{detailEvent.status}</dd>
                  </div>
                  <div>
                    <dt>Creado</dt>
                    <dd>{formatEventDateTime(detailEvent.created_at)}</dd>
                  </div>
                  <div className="event-detail-description">
                    <dt>Descripcion</dt>
                    <dd>{detailEvent.manual_description || "Sin descripcion"}</dd>
                  </div>
                </dl>
              )}
              {!detailLoading && !detailError && detailEvent && (
                <section className="event-image-section">
                  <h3>Imagen del evento</h3>
                  {imageLoading && <p>Cargando imagen...</p>}
                  {imageError && <p className="error">{imageError}</p>}
                  {!imageLoading && !eventImages.length && <p>No hay imagenes subidas.</p>}
                  {!imageLoading && eventImages.length > 0 && (
                    <div className="event-image-grid">
                      {eventImages.map((image) => (
                        <article className="event-image-card" key={image.id}>
                          <div className="event-image-preview">
                            <img src={image.image_url} alt={image.caption || `Imagen de ${detailEvent.title}`} />
                          </div>
                          {image.caption && <p className="event-image-caption">{image.caption}</p>}
                        </article>
                      ))}
                    </div>
                  )}

                  {isImageUploader && (
                    <form className="form image-upload-form" onSubmit={onUploadImage}>
                      <label className="field-label">Subir imagen (JPG, PNG, WEBP, max 5 MB)</label>
                      <input
                        type="file"
                        accept="image/jpeg,image/png,image/webp"
                        onChange={(e) => setSelectedImageFile(e.target.files?.[0] || null)}
                      />
                      <input
                        type="text"
                        placeholder="Caption de la imagen"
                        value={imageCaption}
                        onChange={(e) => setImageCaption(e.target.value)}
                      />
                      {selectedImagePreview && (
                        <div className="event-image-preview pending">
                          <img src={selectedImagePreview} alt="Previsualizacion antes de subir" />
                        </div>
                      )}
                      <button type="submit" disabled={!selectedImageFile || imageUploadLoading}>
                        {imageUploadLoading ? "Subiendo..." : "Guardar imagen"}
                      </button>
                    </form>
                  )}
                  {!isImageUploader && (
                    <p className="muted">Solo la persona que creo el evento puede subir imagenes.</p>
                  )}
                </section>
              )}
              {!detailLoading && !detailError && detailEvent && editMode && (
                <form className="form detail-edit-form" onSubmit={onUpdateEvent}>
                  <h3>Editar evento</h3>
                  <input
                    required
                    placeholder="Titulo"
                    value={editForm.title}
                    onChange={(e) => setEditForm((prev) => ({ ...prev, title: e.target.value }))}
                  />
                  <textarea
                    placeholder="Descripcion"
                    value={editForm.manual_description}
                    onChange={(e) =>
                      setEditForm((prev) => ({ ...prev, manual_description: e.target.value }))
                    }
                  />
                  <label className="field-label">Fecha del evento</label>
                  <CalendarPicker
                    value={editForm.event_date}
                    onChange={(newDate) => setEditForm((prev) => ({ ...prev, event_date: newDate }))}
                  />
                  <input
                    type="time"
                    value={editForm.event_time}
                    onChange={(e) => setEditForm((prev) => ({ ...prev, event_time: e.target.value }))}
                  />
                  <input
                    placeholder="Pais"
                    value={editForm.country}
                    onChange={(e) => setEditForm((prev) => ({ ...prev, country: e.target.value }))}
                  />
                  <input
                    placeholder="Idioma"
                    value={editForm.language}
                    onChange={(e) => setEditForm((prev) => ({ ...prev, language: e.target.value }))}
                  />
                  <button type="submit" disabled={updateLoading || deleteLoading}>
                    {updateLoading ? "Guardando..." : "Guardar cambios"}
                  </button>
                </form>
              )}
            </section>
          )}
        </>
      )}
    </main>
  );
}
