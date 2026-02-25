# Inventory Management System - v2.0
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime

db = SQLAlchemy()


class Product(db.Model):
    """Product model – represents one item in the inventory."""

    __tablename__ = 'products'

    id          = db.Column(db.Integer, primary_key=True)
    name        = db.Column(db.String(100), nullable=False)
    description = db.Column(db.String(255), nullable=True, default='')
    quantity    = db.Column(db.Integer, nullable=False, default=0)
    price       = db.Column(db.Float, nullable=False, default=0.0)
    created_at  = db.Column(db.DateTime, default=datetime.utcnow)

    def to_dict(self):
        """Convert product to dictionary (for JSON responses)."""
        return {
            'id':          self.id,
            'name':        self.name,
            'description': self.description,
            'quantity':    self.quantity,
            'price':       self.price,
            'created_at':  self.created_at.isoformat()
        }

    def __repr__(self):
        return f'<Product {self.name} (qty: {self.quantity})>'
