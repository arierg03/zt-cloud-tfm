INSERT INTO users (username, email, password_hash, role, is_active)
VALUES (
  'admin',
  'admin@example.com',
  'pbkdf2_sha256$120000$2748eccaf169b271289de683405fe040$df90c6b9d001c4d8b2576821b469760bafcecf143541cf61e9fb0203902285c7',
  'admin',
  true
)
ON CONFLICT (email) DO UPDATE
SET
  username = EXCLUDED.username,
  password_hash = EXCLUDED.password_hash,
  role = EXCLUDED.role,
  is_active = EXCLUDED.is_active;

INSERT INTO events (title, manual_description, event_date, country, language, status, created_by)
SELECT
  'Demo Event',
  'Evento inicial para validar la app',
  NOW() + INTERVAL '7 days',
  'Spain',
  'es',
  'pending',
  u.id
FROM users u
WHERE u.email = 'admin@example.com'
AND NOT EXISTS (
  SELECT 1 FROM events e WHERE e.title = 'Demo Event'
);
