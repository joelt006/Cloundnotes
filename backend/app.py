import os
import time
import logging
import psycopg2
from flask import Flask, jsonify, render_template, request, Response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret-change-me")

DATABASE_URL = os.environ["DATABASE_URL"]


def get_db():
    return psycopg2.connect(DATABASE_URL)


def init_db():
    """Create schema on startup, retrying until the database is ready."""
    for attempt in range(30):
        try:
            conn = get_db()
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS notes (
                    id         SERIAL PRIMARY KEY,
                    title      VARCHAR(200) NOT NULL,
                    content    TEXT         NOT NULL,
                    created_at TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
                )
            """)
            cur.execute(
                "CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes(created_at DESC)"
            )
            conn.commit()
            cur.close()
            conn.close()
            logger.info("Database ready.")
            return
        except Exception as exc:
            logger.warning("Waiting for database (attempt %d/30): %s", attempt + 1, exc)
            time.sleep(3)
    logger.error("Could not connect to database after 30 attempts.")


init_db()


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/health")
def health():
    try:
        conn = get_db()
        conn.close()
        return jsonify({"status": "healthy", "database": "connected"})
    except Exception as exc:
        logger.error("Health check failed: %s", exc)
        return jsonify({"status": "unhealthy", "error": str(exc)}), 500


@app.route("/api/notes", methods=["GET"])
def get_notes():
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, title, content, created_at FROM notes ORDER BY created_at DESC"
        )
        notes = [
            {
                "id": row[0],
                "title": row[1],
                "content": row[2],
                "created_at": row[3].isoformat() if row[3] else None,
            }
            for row in cur.fetchall()
        ]
        cur.close()
        return jsonify(notes)
    except Exception as exc:
        logger.error("Error fetching notes: %s", exc)
        return jsonify({"error": "Database error"}), 500
    finally:
        conn.close()


@app.route("/api/notes", methods=["POST"])
def create_note():
    data = request.get_json(silent=True) or {}
    title = (data.get("title") or "").strip()[:200]
    content = (data.get("content") or "").strip()[:5000]

    if not title or not content:
        return jsonify({"error": "Title and content are required"}), 400

    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO notes (title, content) VALUES (%s, %s)"
            " RETURNING id, title, content, created_at",
            (title, content),
        )
        row = cur.fetchone()
        conn.commit()
        cur.close()
        return (
            jsonify({
                "id": row[0],
                "title": row[1],
                "content": row[2],
                "created_at": row[3].isoformat() if row[3] else None,
            }),
            201,
        )
    except Exception as exc:
        conn.rollback()
        logger.error("Error creating note: %s", exc)
        return jsonify({"error": "Database error"}), 500
    finally:
        conn.close()


@app.route("/api/readme")
def get_readme():
    try:
        path = os.path.join(os.path.dirname(__file__), "README.md")
        with open(path, "r") as f:
            return Response(f.read(), mimetype="text/plain; charset=utf-8")
    except FileNotFoundError:
        return Response("README.md not found.", mimetype="text/plain"), 404


@app.route("/api/notes/<int:note_id>", methods=["DELETE"])
def delete_note(note_id):
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute("DELETE FROM notes WHERE id = %s", (note_id,))
        if cur.rowcount == 0:
            return jsonify({"error": "Note not found"}), 404
        conn.commit()
        cur.close()
        return "", 204
    except Exception as exc:
        conn.rollback()
        logger.error("Error deleting note %d: %s", note_id, exc)
        return jsonify({"error": "Database error"}), 500
    finally:
        conn.close()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
