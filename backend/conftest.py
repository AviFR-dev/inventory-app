import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Force SQLite in-memory database for all tests
os.environ['DB_USER'] = 'test'
os.environ['DB_PASSWORD'] = 'test'
os.environ['DB_HOST'] = 'localhost'
os.environ['DB_NAME'] = 'test'