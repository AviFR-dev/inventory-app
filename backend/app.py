from flask import Flask, render_template, request, redirect, url_for, jsonify
from models import db, Product
import os

def create_app(test_config=None):
    app = Flask(__name__, template_folder='../frontend/templates')

    if test_config:
        app.config.update(test_config)
    else:
        app.config['SQLALCHEMY_DATABASE_URI'] = (
            f"postgresql://{os.environ.get('DB_USER', 'postgres')}:"
            f"{os.environ.get('DB_PASSWORD', 'postgres')}@"
            f"{os.environ.get('DB_HOST', 'localhost')}:"
            f"{os.environ.get('DB_PORT', '5432')}/"
            f"{os.environ.get('DB_NAME', 'inventory')}"
        )

    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    db.init_app(app)

    with app.app_context():
        db.create_all()

    @app.route('/')
    def index():
        products = Product.query.all()
        return render_template('index.html', products=products)

    @app.route('/products', methods=['GET'])
    def get_products():
        products = Product.query.all()
        return jsonify([p.to_dict() for p in products]), 200

    @app.route('/products', methods=['POST'])
    def add_product():
        if request.is_json:
            data = request.get_json()
        else:
            data = request.form

        name        = data.get('name', '').strip()
        description = data.get('description', '').strip()
        quantity    = data.get('quantity', 0)
        price       = data.get('price', 0.0)

        if not name:
            if request.is_json:
                return jsonify({'error': 'Name is required'}), 400
            return redirect(url_for('index'))

        product = Product(
            name=name,
            description=description,
            quantity=int(quantity),
            price=float(price)
        )
        db.session.add(product)
        db.session.commit()

        if request.is_json:
            return jsonify(product.to_dict()), 201
        return redirect(url_for('index'))

    @app.route('/products/<int:product_id>', methods=['PUT'])
    def update_product(product_id):
        product = Product.query.get_or_404(product_id)
        data = request.get_json()
        product.name        = data.get('name', product.name)
        product.description = data.get('description', product.description)
        product.quantity    = data.get('quantity', product.quantity)
        product.price       = data.get('price', product.price)
        db.session.commit()
        return jsonify(product.to_dict()), 200

    @app.route('/products/<int:product_id>/delete', methods=['POST'])
    def delete_product(product_id):
        product = Product.query.get_or_404(product_id)
        db.session.delete(product)
        db.session.commit()
        return redirect(url_for('index'))

    @app.route('/health')
    def health():
        return jsonify({'status': 'healthy'}), 200

    return app


if __name__ == '__main__':
    app = create_app()