def test_get_batch_status(client, auth_headers, create_batch_execution):
    batch = create_batch_execution(status="success")
    response = client.get("/batch/status", headers=auth_headers)

    assert response.status_code == 200
    data = response.json()
    assert data["id"] == batch.id
    assert data["status"] == "success"
