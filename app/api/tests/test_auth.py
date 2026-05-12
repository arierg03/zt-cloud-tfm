def test_register_user_success(client):
    payload = {
        "username": "newuser",
        "email": "newuser@example.com",
        "password": "secret123",
    }
    response = client.post("/auth/register", json=payload)
    assert response.status_code == 201
    body = response.json()
    assert "access_token" in body
    assert body["user"]["email"] == payload["email"]


def test_login_user_success(client):
    register_payload = {
        "username": "loginuser",
        "email": "loginuser@example.com",
        "password": "secret123",
    }
    client.post("/auth/register", json=register_payload)

    response = client.post(
        "/auth/login",
        json={"identifier": register_payload["email"], "password": register_payload["password"]},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["user"]["username"] == register_payload["username"]
