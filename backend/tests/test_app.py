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


# ── Health ──────────────────────────────────────────────────────────────────

def test_health_check(client):
    response = client.get('/health')
    assert response.status_code == 200
    assert response.get_json()['status'] == 'healthy'


# ── Products – basic CRUD ────────────────────────────────────────────────────

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
    data = response.get_json()
    assert data['name'] == 'Test Laptop'
    assert data['quantity'] == 10
    assert data['price'] == 999.99


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


# ── Products – new fields ────────────────────────────────────────────────────

def test_add_product_with_sku(client):
    res = client.post('/products', json={
        'name': 'Webcam', 'sku': 'CAM-001', 'quantity': 5, 'price': 49.99
    })
    assert res.status_code == 201
    assert res.get_json()['sku'] == 'CAM-001'


def test_add_product_duplicate_sku(client):
    client.post('/products', json={'name': 'A', 'sku': 'DUP-001', 'quantity': 1, 'price': 1.0})
    res = client.post('/products', json={'name': 'B', 'sku': 'DUP-001', 'quantity': 2, 'price': 2.0})
    assert res.status_code == 409


def test_add_product_with_supplier_and_threshold(client):
    res = client.post('/products', json={
        'name': 'Switch', 'supplier': 'Acme', 'low_stock_threshold': 5,
        'quantity': 20, 'price': 9.99
    })
    assert res.status_code == 201
    data = res.get_json()
    assert data['supplier'] == 'Acme'
    assert data['low_stock_threshold'] == 5


def test_update_product_new_fields(client):
    add = client.post('/products', json={'name': 'Desk', 'quantity': 10, 'price': 200.0})
    pid = add.get_json()['id']
    res = client.put(f'/products/{pid}', json={'supplier': 'FurnitureCo', 'sku': 'DESK-01'})
    data = res.get_json()
    assert data['supplier'] == 'FurnitureCo'
    assert data['sku'] == 'DESK-01'


def test_stock_status_in_dict(client):
    res = client.post('/products', json={'name': 'Cable', 'quantity': 0, 'price': 5.0})
    assert res.get_json()['stock_status'] == 'out_of_stock'


# ── Products – search / filter ───────────────────────────────────────────────

def test_search_products_by_name(client):
    client.post('/products', json={'name': 'Apple iPad', 'quantity': 5, 'price': 500.0})
    client.post('/products', json={'name': 'Samsung Tablet', 'quantity': 3, 'price': 400.0})
    res = client.get('/products?search=Apple')
    results = res.get_json()
    assert len(results) == 1
    assert results[0]['name'] == 'Apple iPad'


def test_filter_products_by_status(client):
    client.post('/products', json={'name': 'A', 'quantity': 0, 'price': 1.0})
    client.post('/products', json={'name': 'B', 'quantity': 50, 'price': 1.0})
    res = client.get('/products?status=out_of_stock')
    results = res.get_json()
    assert len(results) == 1
    assert results[0]['name'] == 'A'


# ── Categories ───────────────────────────────────────────────────────────────

def test_add_category(client):
    res = client.post('/categories', json={'name': 'Electronics'})
    assert res.status_code == 201
    assert res.get_json()['name'] == 'Electronics'


def test_add_duplicate_category(client):
    client.post('/categories', json={'name': 'Electronics'})
    res = client.post('/categories', json={'name': 'Electronics'})
    assert res.status_code == 409


def test_add_category_missing_name(client):
    res = client.post('/categories', json={})
    assert res.status_code == 400


def test_get_categories(client):
    client.post('/categories', json={'name': 'Electronics'})
    client.post('/categories', json={'name': 'Furniture'})
    res = client.get('/categories')
    assert res.status_code == 200
    assert len(res.get_json()) == 2


def test_delete_category(client):
    res = client.post('/categories', json={'name': 'Temp'})
    cat_id = res.get_json()['id']
    del_res = client.delete(f'/categories/{cat_id}')
    assert del_res.status_code == 200
    assert len(client.get('/categories').get_json()) == 0


def test_add_product_with_category(client):
    cat = client.post('/categories', json={'name': 'Electronics'}).get_json()
    res = client.post('/products', json={
        'name': 'TV', 'quantity': 3, 'price': 799.0,
        'category_id': cat['id']
    })
    assert res.status_code == 201
    data = res.get_json()
    assert data['category_id'] == cat['id']
    assert data['category'] == 'Electronics'


def test_delete_category_unlinks_products(client):
    cat = client.post('/categories', json={'name': 'Temp'}).get_json()
    prod = client.post('/products', json={
        'name': 'Gadget', 'quantity': 1, 'price': 10.0,
        'category_id': cat['id']
    }).get_json()
    client.delete(f"/categories/{cat['id']}")
    products = client.get('/products').get_json()
    assert products[0]['category_id'] is None


# ── Stock Movements ──────────────────────────────────────────────────────────

def test_stock_adjustment_in(client):
    add = client.post('/products', json={'name': 'Widget', 'quantity': 10, 'price': 5.0})
    pid = add.get_json()['id']
    res = client.post(f'/products/{pid}/adjust', json={'delta': 5, 'reason': 'Restock'})
    assert res.status_code == 200
    assert res.get_json()['product']['quantity'] == 15


def test_stock_adjustment_out(client):
    add = client.post('/products', json={'name': 'Widget', 'quantity': 10, 'price': 5.0})
    pid = add.get_json()['id']
    res = client.post(f'/products/{pid}/adjust', json={'delta': -3, 'reason': 'Sale'})
    assert res.status_code == 200
    assert res.get_json()['product']['quantity'] == 7


def test_stock_adjustment_insufficient(client):
    add = client.post('/products', json={'name': 'Widget', 'quantity': 2, 'price': 5.0})
    pid = add.get_json()['id']
    res = client.post(f'/products/{pid}/adjust', json={'delta': -5})
    assert res.status_code == 400


def test_stock_adjustment_zero_delta(client):
    add = client.post('/products', json={'name': 'Widget', 'quantity': 5, 'price': 5.0})
    pid = add.get_json()['id']
    res = client.post(f'/products/{pid}/adjust', json={'delta': 0})
    assert res.status_code == 400


def test_get_movements(client):
    add = client.post('/products', json={'name': 'Sprocket', 'quantity': 10, 'price': 2.0})
    pid = add.get_json()['id']
    client.post(f'/products/{pid}/adjust', json={'delta': 5, 'reason': 'Purchase'})
    client.post(f'/products/{pid}/adjust', json={'delta': -2, 'reason': 'Sale'})
    res = client.get(f'/products/{pid}/movements')
    assert res.status_code == 200
    movements = res.get_json()
    assert len(movements) == 2


# ── CSV Export ───────────────────────────────────────────────────────────────

def test_export_csv(client):
    client.post('/products', json={'name': 'ExportMe', 'quantity': 10, 'price': 9.99})
    res = client.get('/products/export')
    assert res.status_code == 200
    assert 'text/csv' in res.content_type
    content = res.data.decode('utf-8')
    assert 'ExportMe' in content
    assert 'ID' in content  # header row
