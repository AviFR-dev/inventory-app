from flask_sqlalchemy import SQLAlchemy
from datetime import datetime

db = SQLAlchemy()


class Category(db.Model):
    """Category model – groups products into logical families."""

    __tablename__ = 'categories'

    id       = db.Column(db.Integer, primary_key=True)
    name     = db.Column(db.String(100), nullable=False, unique=True)
    products = db.relationship('Product', backref='category', lazy=True)

    def to_dict(self):
        return {'id': self.id, 'name': self.name, 'product_count': len(self.products)}

    def __repr__(self):
        return f'<Category {self.name}>'


class Product(db.Model):
    """Product model – represents one item in the inventory."""

    __tablename__ = 'products'

    id                  = db.Column(db.Integer, primary_key=True)
    name                = db.Column(db.String(100), nullable=False)
    sku                 = db.Column(db.String(50), nullable=True, unique=True)
    description         = db.Column(db.String(255), nullable=True, default='')
    quantity            = db.Column(db.Integer, nullable=False, default=0)
    price               = db.Column(db.Float, nullable=False, default=0.0)
    low_stock_threshold = db.Column(db.Integer, nullable=False, default=10)
    supplier            = db.Column(db.String(100), nullable=True, default='')
    category_id         = db.Column(db.Integer, db.ForeignKey('categories.id'), nullable=True)
    created_at          = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at          = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    movements = db.relationship(
        'StockMovement', backref='product', lazy=True, cascade='all, delete-orphan'
    )

    def stock_status(self):
        if self.quantity == 0:
            return 'out_of_stock'
        if self.quantity <= self.low_stock_threshold:
            return 'low_stock'
        return 'in_stock'

    def to_dict(self):
        """Convert product to dictionary (for JSON responses)."""
        return {
            'id':                  self.id,
            'name':                self.name,
            'sku':                 self.sku,
            'description':         self.description,
            'quantity':            self.quantity,
            'price':               self.price,
            'low_stock_threshold': self.low_stock_threshold,
            'supplier':            self.supplier,
            'category_id':         self.category_id,
            'category':            self.category.name if self.category else None,
            'stock_status':        self.stock_status(),
            'created_at':          self.created_at.isoformat(),
            'updated_at':          self.updated_at.isoformat() if self.updated_at else None,
        }

    def __repr__(self):
        return f'<Product {self.name} (qty: {self.quantity})>'


class StockMovement(db.Model):
    """Audit log of every stock change (in / out) for a product."""

    __tablename__ = 'stock_movements'

    id         = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, db.ForeignKey('products.id'), nullable=False)
    delta      = db.Column(db.Integer, nullable=False)   # positive = stock in, negative = stock out
    reason     = db.Column(db.String(255), nullable=True, default='')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def to_dict(self):
        return {
            'id':         self.id,
            'product_id': self.product_id,
            'delta':      self.delta,
            'reason':     self.reason,
            'created_at': self.created_at.isoformat(),
        }

    def __repr__(self):
        return f'<StockMovement product={self.product_id} delta={self.delta}>'
