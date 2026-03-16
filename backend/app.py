import csv
import io
import os

from flask import Flask, render_template, request, redirect, url_for, jsonify, Response
from sqlalchemy import func

from models import db, Category, Product, StockMovement


def create_app(test_config=None):
    app = Flask(__name__)
    app.template_folder = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'frontend', 'templates'
    )

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

    # ──────────────────────────────────────────────
    # HTML page
    # ──────────────────────────────────────────────

    @app.route('/')
    def index():
        search       = request.args.get('search', '').strip()
        category_id  = request.args.get('category_id', '').strip()
        status_filter = request.args.get('status', '').strip()
        page         = request.args.get('page', 1, type=int)
        per_page     = 10

        query = Product.query

        if search:
            like = f'%{search}%'
            query = query.filter(
                db.or_(
                    Product.name.ilike(like),
                    Product.sku.ilike(like),
                    Product.description.ilike(like),
                    Product.supplier.ilike(like),
                )
            )

        if category_id:
            query = query.filter(Product.category_id == int(category_id))

        if status_filter == 'in_stock':
            query = query.filter(Product.quantity > Product.low_stock_threshold)
        elif status_filter == 'low_stock':
            query = query.filter(
                Product.quantity > 0,
                Product.quantity <= Product.low_stock_threshold
            )
        elif status_filter == 'out_of_stock':
            query = query.filter(Product.quantity == 0)

        total    = query.count()
        products = query.order_by(Product.created_at.desc()) \
                        .offset((page - 1) * per_page).limit(per_page).all()

        categories = Category.query.order_by(Category.name).all()

        total_value = db.session.query(
            func.coalesce(func.sum(Product.price * Product.quantity), 0.0)
        ).scalar()

        stats = {
            'total':         Product.query.count(),
            'in_stock':      db.session.query(Product).filter(
                                 Product.quantity > Product.low_stock_threshold).count(),
            'low_stock':     db.session.query(Product).filter(
                                 Product.quantity > 0,
                                 Product.quantity <= Product.low_stock_threshold).count(),
            'out_of_stock':  Product.query.filter(Product.quantity == 0).count(),
            'total_value':   round(float(total_value), 2),
        }

        pagination = {
            'page':     page,
            'per_page': per_page,
            'total':    total,
            'pages':    max(1, (total + per_page - 1) // per_page),
        }

        return render_template(
            'index.html',
            products=products,
            categories=categories,
            stats=stats,
            pagination=pagination,
            search=search,
            category_id=category_id,
            status_filter=status_filter,
        )

    # ──────────────────────────────────────────────
    # Category endpoints
    # ──────────────────────────────────────────────

    @app.route('/categories', methods=['GET'])
    def get_categories():
        cats = Category.query.order_by(Category.name).all()
        return jsonify([c.to_dict() for c in cats]), 200

    @app.route('/categories', methods=['POST'])
    def add_category():
        data = request.get_json() if request.is_json else request.form
        name = (data.get('name') or '').strip()
        if not name:
            return jsonify({'error': 'Name is required'}), 400
        if Category.query.filter_by(name=name).first():
            return jsonify({'error': 'Category already exists'}), 409
        cat = Category(name=name)
        db.session.add(cat)
        db.session.commit()
        return jsonify(cat.to_dict()), 201

    @app.route('/categories/<int:cat_id>', methods=['DELETE'])
    def delete_category(cat_id):
        cat = Category.query.get_or_404(cat_id)
        # Unlink products before deleting
        Product.query.filter_by(category_id=cat_id).update({'category_id': None})
        db.session.delete(cat)
        db.session.commit()
        return jsonify({'message': 'Deleted'}), 200

    # ──────────────────────────────────────────────
    # Product endpoints (JSON API)
    # ──────────────────────────────────────────────

    @app.route('/products', methods=['GET'])
    def get_products():
        search        = request.args.get('search', '').strip()
        category_id   = request.args.get('category_id', '').strip()
        status_filter = request.args.get('status', '').strip()

        query = Product.query

        if search:
            like = f'%{search}%'
            query = query.filter(
                db.or_(
                    Product.name.ilike(like),
                    Product.sku.ilike(like),
                    Product.description.ilike(like),
                )
            )

        if category_id:
            query = query.filter(Product.category_id == int(category_id))

        if status_filter == 'in_stock':
            query = query.filter(Product.quantity > Product.low_stock_threshold)
        elif status_filter == 'low_stock':
            query = query.filter(
                Product.quantity > 0,
                Product.quantity <= Product.low_stock_threshold
            )
        elif status_filter == 'out_of_stock':
            query = query.filter(Product.quantity == 0)

        products = query.order_by(Product.created_at.desc()).all()
        return jsonify([p.to_dict() for p in products]), 200

    @app.route('/products', methods=['POST'])
    def add_product():
        if request.is_json:
            data = request.get_json()
        else:
            data = request.form

        name = (data.get('name') or '').strip()
        if not name:
            if request.is_json:
                return jsonify({'error': 'Name is required'}), 400
            return redirect(url_for('index'))

        sku = (data.get('sku') or '').strip() or None
        if sku and Product.query.filter_by(sku=sku).first():
            if request.is_json:
                return jsonify({'error': 'SKU already exists'}), 409
            return redirect(url_for('index'))

        category_id = data.get('category_id') or None
        if category_id:
            category_id = int(category_id)

        product = Product(
            name=name,
            sku=sku,
            description=(data.get('description') or '').strip(),
            quantity=int(data.get('quantity', 0)),
            price=float(data.get('price', 0.0)),
            low_stock_threshold=int(data.get('low_stock_threshold', 10)),
            supplier=(data.get('supplier') or '').strip(),
            category_id=category_id,
        )
        db.session.add(product)
        db.session.commit()

        if request.is_json:
            return jsonify(product.to_dict()), 201
        return redirect(url_for('index'))

    @app.route('/products/<int:product_id>', methods=['PUT'])
    def update_product(product_id):
        product = Product.query.get_or_404(product_id)
        data    = request.get_json()

        if 'name' in data:
            product.name = data['name']
        if 'sku' in data:
            new_sku = (data['sku'] or '').strip() or None
            if new_sku and new_sku != product.sku:
                if Product.query.filter(Product.sku == new_sku, Product.id != product_id).first():
                    return jsonify({'error': 'SKU already exists'}), 409
            product.sku = new_sku
        if 'description' in data:
            product.description = data['description']
        if 'quantity' in data:
            product.quantity = int(data['quantity'])
        if 'price' in data:
            product.price = float(data['price'])
        if 'low_stock_threshold' in data:
            product.low_stock_threshold = int(data['low_stock_threshold'])
        if 'supplier' in data:
            product.supplier = data['supplier']
        if 'category_id' in data:
            product.category_id = int(data['category_id']) if data['category_id'] else None

        db.session.commit()
        return jsonify(product.to_dict()), 200

    @app.route('/products/<int:product_id>/delete', methods=['POST'])
    def delete_product(product_id):
        product = Product.query.get_or_404(product_id)
        db.session.delete(product)
        db.session.commit()
        return redirect(url_for('index'))

    # ──────────────────────────────────────────────
    # Stock movement endpoints
    # ──────────────────────────────────────────────

    @app.route('/products/<int:product_id>/adjust', methods=['POST'])
    def adjust_stock(product_id):
        product = Product.query.get_or_404(product_id)
        data    = request.get_json()
        delta   = int(data.get('delta', 0))
        reason  = (data.get('reason') or '').strip()

        if delta == 0:
            return jsonify({'error': 'Delta cannot be zero'}), 400

        new_qty = product.quantity + delta
        if new_qty < 0:
            return jsonify({'error': 'Insufficient stock'}), 400

        product.quantity = new_qty
        movement = StockMovement(product_id=product_id, delta=delta, reason=reason)
        db.session.add(movement)
        db.session.commit()
        return jsonify({'product': product.to_dict(), 'movement': movement.to_dict()}), 200

    @app.route('/products/<int:product_id>/movements', methods=['GET'])
    def get_movements(product_id):
        Product.query.get_or_404(product_id)
        movements = (
            StockMovement.query
            .filter_by(product_id=product_id)
            .order_by(StockMovement.created_at.desc())
            .all()
        )
        return jsonify([m.to_dict() for m in movements]), 200

    # ──────────────────────────────────────────────
    # CSV export
    # ──────────────────────────────────────────────

    @app.route('/products/export')
    def export_products():
        products = Product.query.order_by(Product.name).all()

        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow([
            'ID', 'Name', 'SKU', 'Category', 'Description',
            'Quantity', 'Price', 'Low Stock Threshold',
            'Supplier', 'Status', 'Created At'
        ])
        for p in products:
            writer.writerow([
                p.id, p.name, p.sku or '',
                p.category.name if p.category else '',
                p.description or '',
                p.quantity, p.price, p.low_stock_threshold,
                p.supplier or '', p.stock_status(),
                p.created_at.strftime('%Y-%m-%d %H:%M:%S'),
            ])

        return Response(
            output.getvalue(),
            mimetype='text/csv',
            headers={'Content-Disposition': 'attachment; filename=inventory.csv'},
        )

    # ──────────────────────────────────────────────
    # Health check
    # ──────────────────────────────────────────────

    @app.route('/health')
    def health():
        return jsonify({'status': 'healthy'}), 200

    return app


if __name__ == '__main__':
    app = create_app()
    debug_mode = os.environ.get('APP_ENV', 'production') == 'development'
    app.run(host='0.0.0.0', port=5000, debug=debug_mode)
