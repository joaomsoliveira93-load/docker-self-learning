const databaseName = "docker_self_learning";

db = db.getSiblingDB(databaseName);

db.users.drop();

db.createCollection("users");

db.users.insertMany([
  {
    id: 1,
    name: "John Doe",
    email: "john@example.com",
    password: "password123"
  },
  {
    id: 2,
    name: "Jane Smith",
    email: "jane@example.com",
    password: "password456"
  },
  {
    id: 3,
    name: "Alex Johnson",
    email: "alex@example.com",
    password: "password789"
  }
]);

print("MongoDB users collection restored successfully.");