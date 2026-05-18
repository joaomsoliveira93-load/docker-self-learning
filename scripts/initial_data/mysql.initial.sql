DROP TABLE IF EXISTS users;

CREATE TABLE users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(150) NOT NULL UNIQUE,
  password VARCHAR(255) NOT NULL
);

INSERT INTO users (id, name, email, password) VALUES
  (1, 'John Doe', 'john@example.com', 'password123'),
  (2, 'Jane Smith', 'jane@example.com', 'password456'),
  (3, 'Alex Johnson', 'alex@example.com', 'password789');