# Задание 7. Проектирование схем коллекций для шардирования данных

## Обзор

Онлайн-магазин «Мобильный мир» использует три коллекции MongoDB:
- **orders** — заказы клиентов
- **products** — каталог товаров
- **carts** — корзины (гостевые и пользовательские)

---

## 1. Коллекция `orders`

### Схема документа

```javascript
{
  _id: ObjectId("..."),
  customer_id: ObjectId("user_123"),
  created_at: ISODate("2024-11-29T10:30:00Z"),
  items: [
    { product_id: ObjectId("prod_1"), name: "Смартфон X", quantity: 1, price: 49990 },
    { product_id: ObjectId("prod_2"), name: "Чехол", quantity: 2, price: 990 }
  ],
  status: "delivered",  // "pending" | "paid" | "shipped" | "delivered" | "cancelled"
  total_amount: 51970,
  geo_zone: "moscow"
}
```

### Анализ кандидатов для шард-ключа

Когда mongos получает запрос от клиента, происходит следующее:
- mongos смотрит в Config Server: "где лежит customer_id = X?"
- направляет запрос на нужный шард (targeted) или на все (scatter-gather)
- собирает результаты и возвращает клиенту

Будем оценивать кандидатов по следующим критериям:
1. **Кардинальность** — чем выше, тем лучше (вес = 1)
2. **Частота записи** — чем равномернее, тем лучше (вес = 1)
3. **Изоляция запросов** — чем чаще запросы идут на один шард, тем лучше (вес = 2)

Изоляция - основной критерий, поэтому назначим ему двойной вес. 

`Итоговая оценка = Кардинальность + Частота записи + (Изоляция × Вес)`


| Кандидат | Кардинальность | Частота записи | Изоляция запросов | Оценка |
|----------|----------------|----------------|-------------------|--------|
| `_id` | Высокая (+) | Равномерная (+) | Нет (-) | 2 |
| `customer_id` | Высокая (+) | Неравномерная (?) | Да (+) | 3 |
| `geo_zone` | Низкая (-) | Неравномерная (-) | Да (+) | 1 |
| `{customer_id, _id}` | Очень высокая (+) | Равномерная (+) | Да (+) | 4 |

### Выбранная стратегия

**Шард-ключ:** `{ customer_id: 1, _id: 1 }` (Range sharding)

```javascript
sh.shardCollection("shop.orders", { customer_id: 1, _id: 1 })
```

### Обоснование

| Критерий | Почему подходит |
|----------|-----------------|
| **Изоляция запросов** | Все заказы одного клиента на одном шарде → `db.orders.find({customer_id: X})` идёт на один шард |
| **Кардинальность** | Составной ключ даёт уникальность даже для активных клиентов |
| **Равномерность записи** | `_id` в составе ключа предотвращает hotspot на активных клиентах |
| **История заказов** | Быстрый поиск всех заказов клиента без scatter-gather |

### Индексы

```javascript
// Шард-ключ создаёт индекс автоматически
// Дополнительные индексы:
db.orders.createIndex({ status: 1, created_at: -1 })  // для админки "все pending заказы"
db.orders.createIndex({ geo_zone: 1, created_at: -1 }) // для аналитики по регионам
```

---

## 2. Коллекция `products`

### Схема документа

```javascript
{
  _id: ObjectId("..."),
  name: "Смартфон X",
  category: "electronics",
  price: 49990,
  stock: {
    "moscow": 150,
    "spb": 80,
    "ekb": 50,
    "kaliningrad": 30
  },
  attributes: {
    color: "black",
    storage: "128GB",
    brand: "BrandX"
  },
  created_at: ISODate("2024-01-15T00:00:00Z"),
  updated_at: ISODate("2024-11-29T12:00:00Z")
}
```

### Анализ кандидатов для шард-ключа

| Кандидат | Кардинальность | Частота записи | Изоляция запросов | Оценка |
|----------|----------------|----------------|-------------------|--------|
| `_id` (hashed) | Очень высокая (+) | Равномерная (+) | Только по _id (?) | 3 |
| `category` | Низкая (-) | Неравномерная (-) | Да (+) | 1 |
| `{category, _id}` | Высокая (+) | Неравномерная (?) | По категории (+) | 3 |

### Выбранная стратегия

**Шард-ключ:** `{ _id: "hashed" }` (Hashed sharding)

```javascript
sh.shardCollection("shop.products", { _id: "hashed" })
```

### Обоснование

| Критерий | Почему подходит |
|----------|-----------------|
| **Равномерное распределение** | Hashed `_id` даёт идеальное распределение по шардам |
| **Частые обновления stock** | Запись распределена равномерно, нет hotspot |
| **Страница товара** | `db.products.findOne({_id: X})` — targeted query на один шард |
| **Поиск по категории** | Scatter-gather, но читаем параллельно со всех шардов — приемлемо для каталога |

### Индексы

```javascript
// Для поиска и фильтрации в каталоге:
db.products.createIndex({ category: 1, price: 1 })
db.products.createIndex({ "attributes.brand": 1, category: 1 })
db.products.createIndex({ name: "text" })  // полнотекстовый поиск
```

---

## 3. Коллекция `carts`

### Схема документа

```javascript
{
  _id: ObjectId("..."),
  user_id: ObjectId("user_123"),  // null для гостей
  session_id: "sess_abc123",      // null для залогиненных
  items: [
    { product_id: ObjectId("prod_1"), quantity: 2 },
    { product_id: ObjectId("prod_2"), quantity: 1 }
  ],
  status: "active",  // "active" | "ordered" | "abandoned"
  created_at: ISODate("2024-11-29T10:00:00Z"),
  updated_at: ISODate("2024-11-29T10:30:00Z"),
  expires_at: ISODate("2024-12-06T10:00:00Z")  // TTL: 7 дней
}
```

### Анализ кандидатов для шард-ключа

| Кандидат | Кардинальность | Частота записи | Изоляция запросов | Оценка |
|----------|----------------|----------------|-------------------|--------|
| `_id` (hashed) | Очень высокая (+) | Равномерная (+) | Нет (-) | 2 |
| `user_id` | Высокая, но null (-) | Неравномерная (-) | Для users (+) | 1 |
| `session_id` | Высокая, но null (-) | Неравномерная (-) | Для guests (+) | 1 |
| `{session_id, _id}` | Очень высокая (+) | Равномерная (+) | Для guests (+) | 4 |

### Выбранная стратегия

**Шард-ключ:** `{ session_id: 1, _id: 1 }` (Range sharding)

```javascript
sh.shardCollection("shop.carts", { session_id: 1, _id: 1 })
```

### Обоснование

| Критерий | Почему подходит |
|----------|-----------------|
| **Гостевые корзины** | `session_id` есть у всех корзин (генерируется всегда) |
| **Targeted queries** | `db.carts.find({session_id: X, status: "active"})` — один шард |
| **Высокая кардинальность** | session_id уникален, `_id` добавляет гранулярность |
| **TTL очистка** | Работает корректно с любым шард-ключом |

### Важно: Унификация идентификатора

Для корректной работы шардирования **всегда генерируем `session_id`**, даже для залогиненных пользователей:

```javascript
// При создании корзины:
{
  session_id: "sess_" + uuid(),  // генерируется ВСЕГДА
  user_id: user._id || null,     // только для залогиненных
  ...
}
```

### Индексы

```javascript
// Поиск активной корзины пользователя:
db.carts.createIndex({ user_id: 1, status: 1 })

// Поиск гостевой корзины:
db.carts.createIndex({ session_id: 1, status: 1 })

// TTL индекс для автоматической очистки:
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
```

---

## 4. Сводная таблица

| Коллекция | Шард-ключ | Стратегия | Основной паттерн запросов |
|-----------|-----------|-----------|---------------------------|
| `orders` | `{customer_id: 1, _id: 1}` | Range | История заказов клиента |
| `products` | `{_id: "hashed"}` | Hashed | Страница товара, обновление stock |
| `carts` | `{session_id: 1, _id: 1}` | Range | Получение активной корзины |

---

## 5. Примеры команд MongoDB

### Настройка шардирования

```javascript
// Подключаемся к mongos
mongosh "mongodb://localhost:27017"

// Включаем шардирование для базы данных
sh.enableSharding("shop")

// Шардируем коллекции
sh.shardCollection("shop.orders", { customer_id: 1, _id: 1 })
sh.shardCollection("shop.products", { _id: "hashed" })
sh.shardCollection("shop.carts", { session_id: 1, _id: 1 })
```

### Типичные операции

```javascript
// === ORDERS ===

// Создание заказа
db.orders.insertOne({
  customer_id: ObjectId("673f..."),
  created_at: new Date(),
  items: [
    { product_id: ObjectId("prod1"), name: "Смартфон X", quantity: 1, price: 49990 }
  ],
  status: "pending",
  total_amount: 49990,
  geo_zone: "moscow"
})

// История заказов клиента (targeted query → один шард)
db.orders.find({ customer_id: ObjectId("673f...") }).sort({ created_at: -1 })

// Статус заказа
db.orders.findOne({ _id: ObjectId("order_id") }, { status: 1 })


// === PRODUCTS ===

// Страница товара (targeted query → один шард)
db.products.findOne({ _id: ObjectId("prod1") })

// Поиск по категории с фильтром цены (scatter-gather)
db.products.find({
  category: "electronics",
  price: { $gte: 10000, $lte: 50000 }
}).limit(20)

// Атомарное обновление остатков
db.products.updateOne(
  { _id: ObjectId("prod1"), "stock.moscow": { $gte: 1 } },
  { $inc: { "stock.moscow": -1 }, $set: { updated_at: new Date() } }
)


// === CARTS ===

// Создание корзины
db.carts.insertOne({
  session_id: "sess_abc123",
  user_id: null,
  items: [],
  status: "active",
  created_at: new Date(),
  updated_at: new Date(),
  expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)  // +7 дней
})

// Получение активной корзины гостя (targeted query → один шард)
db.carts.findOne({ session_id: "sess_abc123", status: "active" })

// Добавление товара в корзину
db.carts.updateOne(
  { session_id: "sess_abc123", status: "active" },
  {
    $push: { items: { product_id: ObjectId("prod1"), quantity: 1 } },
    $set: { updated_at: new Date() }
  }
)

// Слияние гостевой корзины в пользовательскую
const guestCart = db.carts.findOne({ session_id: "sess_abc123", status: "active" })
if (guestCart && guestCart.items.length > 0) {
  db.carts.updateOne(
    { user_id: ObjectId("user_123"), status: "active" },
    {
      $push: { items: { $each: guestCart.items } },
      $set: { updated_at: new Date() }
    },
    { upsert: true }
  )
  db.carts.updateOne(
    { _id: guestCart._id },
    { $set: { status: "abandoned", updated_at: new Date() } }
  )
}

// Оформление заказа (смена статуса корзины)
db.carts.updateOne(
  { session_id: "sess_abc123", status: "active" },
  { $set: { status: "ordered", updated_at: new Date() } }
)
```
