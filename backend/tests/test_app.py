import pytest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import create_app
from models import db


@pytest.fixture
def client():
    app = create_app({
        'TESTING': True,
        'SQLALCHEMY_DATABASE_URI': 'sqlite:///:memory:'
    })
    with app.app_context():
        db.create_all()
        yield app.test_client()
        db.drop_all()


def test_health_check(client):
    response = client.get('/health')
    assert response.status_code == 200
    assert response.get_json()['status'] == 'healthy'


def test_get_products_empty(client):
    response = client.get('/products')
    assert response.status_code == 200
    assert response.get_json() == []


def test_add_product(client):
    response = client.post('/products', json={
        'name': 'Test Laptop', 'description': 'A test product',
        'quantity': 10, 'price': 999.99
    })
    assert response.status_code == 201
    assert response.get_json()['name'] == 'Test Laptop'


def test_add_product_missing_name(client):
    response = client.post('/products', json={'quantity': 5, 'price': 10.0})
    assert response.status_code == 400


def test_get_products_after_add(client):
    client.post('/products', json={'name': 'Keyboard', 'quantity': 50, 'price': 79.99})
    assert len(client.get('/products').get_json()) == 1


def test_update_product(client):
    add = client.post('/products', json={'name': 'Mouse', 'quantity': 20, 'price': 29.99})
    pid = add.get_json()['id']
    response = client.put(f'/products/{pid}', json={'quantity': 5})
    assert response.get_json()['quantity'] == 5


def test_delete_product(client):
    add = client.post('/products', json={'name': 'Monitor', 'quantity': 3, 'price': 299.99})
    pid = add.get_json()['id']
    client.post(f'/products/{pid}/delete')
    assert len(client.get('/products').get_json()) == 0