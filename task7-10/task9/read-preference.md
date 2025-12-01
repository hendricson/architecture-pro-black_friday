# Задание 9. Настройка чтения с реплик и консистентность

## 1. Таблица операций чтения

### 1.1. Коллекция `products`

| Операция | Реплика | Read Preference | Допустимый lag | Обоснование |
|----------|---------|-----------------|----------------|-------------|
| Просмотр каталога | Secondary | `secondaryPreferred` | до 5 сек | Небольшая задержка в отображении цены/описания некритична |
| Страница товара | Secondary | `secondaryPreferred` | до 5 сек | Пользователь видит информацию, но не покупает |
| Поиск товаров | Secondary | `secondaryPreferred` | до 5 сек | Поисковая выдача может быть слегка устаревшей |
| **Проверка stock перед покупкой** | **Primary** | `primary` | **0** | **Критично:** риск продажи отсутствующего товара |
| **Резервирование товара** | **Primary** | `primary` | **0** | **Критично:** race condition при параллельных покупках |
| Админка: список товаров | Secondary | `secondaryPreferred` | до 10 сек | Отчёты могут быть слегка устаревшими |
| Админка: редактирование товара | Primary | `primary` | 0 | Админ должен видеть актуальные данные перед изменением |

### 1.2. Коллекция `orders`

| Операция | Реплика | Read Preference | Допустимый lag | Обоснование |
|----------|---------|-----------------|----------------|-------------|
| История заказов пользователя | Secondary | `secondaryPreferred` | до 30 сек | Старые заказы редко меняются |
| **Статус текущего заказа** | **Primary** | `primaryPreferred` | **до 2 сек** | Пользователь ожидает актуальный статус после оплаты |
| **Только что созданный заказ** | **Primary** | `primary` | **0** | Read-your-writes: пользователь должен увидеть свой заказ |
| Детали заказа (старого) | Secondary | `secondaryPreferred` | до 60 сек | Исторические данные стабильны |
| **Обработка заказа (fulfillment)** | **Primary** | `primary` | **0** | **Критично:** дублирование отправки при stale read |
| Аналитика/отчёты | Secondary | `secondary` | до 5 мин | Отчёты допускают задержку |
| Поиск заказа по номеру (support) | Primary | `primaryPreferred` | до 2 сек | Поддержка должна видеть актуальный статус |

### 1.3. Коллекция `carts`

| Операция | Реплика | Read Preference | Допустимый lag | Обоснование |
|----------|---------|-----------------|----------------|-------------|
| **Просмотр корзины** | **Primary** | `primary` | **0** | Пользователь только что добавил товар — ожидает увидеть его |
| **Добавление в корзину** | **Primary** | `primary` | **0** | Read-modify-write: нужна актуальная корзина |
| **Слияние корзин при логине** | **Primary** | `primary` | **0** | **Критично:** потеря товаров при stale read |
| **Оформление заказа из корзины** | **Primary** | `primary` | **0** | **Критично:** корзина должна быть актуальной |
| Очистка expired корзин (batch) | Secondary | `secondary` | до 5 мин | Фоновый процесс, некритично |
| Аналитика брошенных корзин | Secondary | `secondary` | до 1 час | Статистика допускает задержку |

---

## 2. Сводная таблица по коллекциям

| Коллекция | % операций на Primary | % операций на Secondary | Основной паттерн |
|-----------|----------------------|------------------------|------------------|
| `products` | ~20% (покупка, резерв) | ~80% (просмотр) | Много чтений каталога, критичны только покупки |
| `orders` | ~40% (текущие заказы) | ~60% (история, отчёты) | Свежие заказы на primary, старые на secondary |
| `carts` | ~90% (все действия) | ~10% (batch, аналитика) | Почти всё на primary из-за read-your-writes |

---

## 3. Допустимая задержка репликации

### 3.1. Категории задержки

| Категория | Допустимый lag | Примеры операций |
|-----------|----------------|------------------|
| **Real-time** | 0 (только primary) | Покупка, резерв stock, просмотр корзины |
| **Near real-time** | до 2 сек | Статус текущего заказа, данные для support |
| **Eventually consistent** | до 30 сек | История заказов, каталог товаров |
| **Batch/Analytics** | до 5-60 мин | Отчёты, аналитика, cleanup jobs |

### 3.2. Настройка maxStalenessSeconds

```javascript
// Для каталога: допускаем до 5 секунд задержки
db.products.find({ category: "electronics" })
  .readPref("secondaryPreferred", [], { maxStalenessSeconds: 5 })

// Для истории заказов: допускаем до 30 секунд
db.orders.find({ customer_id: userId, status: "delivered" })
  .readPref("secondaryPreferred", [], { maxStalenessSeconds: 30 })

// Для отчётов: допускаем до 5 минут
db.orders.aggregate([...reportPipeline...])
  .readPref("secondary", [], { maxStalenessSeconds: 300 })
```

---

## 4. Обоснование выбора

### 4.1. Требования к консистентности

| Требование | Когда применяется | Read Preference |
|------------|-------------------|-----------------|
| **Strong consistency** | Финансовые операции, inventory | `primary` |
| **Read-your-writes** | Пользователь видит свои действия | `primary` или `primaryPreferred` |
| **Eventual consistency** | Просмотр, история, отчёты | `secondaryPreferred` или `secondary` |

### 4.2. Частота обновлений

| Коллекция | Частота записи | Влияние на выбор |
|-----------|---------------|------------------|
| `products` | Низкая (обновление stock при покупке) | Большинство reads безопасны на secondary |
| `orders` | Средняя (создание + смена статусов) | Свежие заказы требуют primary |
| `carts` | Высокая (каждое действие пользователя) | Primary для интерактивных операций |

### 4.3. Бизнес-риски

| Риск | Последствие | Как избежать |
|------|-------------|--------------|
| **Overselling** (продажа отсутствующего товара) | Отмена заказа, негатив клиента | `primary` для проверки stock |
| **Потеря товаров в корзине** | Клиент не видит добавленный товар | `primary` для операций с корзиной |
| **Устаревший статус заказа** | Клиент думает, что заказ не оплачен | `primary` для свежих заказов |
| **Дублирование отправки** | Двойная доставка, убытки | `primary` для fulfillment |

---

## 5. Примеры кода

### 5.1. Настройка в приложении (Node.js / Mongoose)

```javascript
const mongoose = require('mongoose');

// Connection с разными read preferences для разных операций
const primaryConnection = mongoose.createConnection(uri, {
  readPreference: 'primary'
});

const secondaryConnection = mongoose.createConnection(uri, {
  readPreference: 'secondaryPreferred',
  maxStalenessSeconds: 10
});

// Модели для разных типов чтения
const ProductCatalog = secondaryConnection.model('Product', productSchema);  // просмотр
const ProductStock = primaryConnection.model('Product', productSchema);       // покупка

const OrderHistory = secondaryConnection.model('Order', orderSchema);         // история
const OrderCurrent = primaryConnection.model('Order', orderSchema);           // текущие

const Cart = primaryConnection.model('Cart', cartSchema);                     // всегда primary
```

### 5.2. Пример: безопасная проверка stock

```javascript
async function purchaseProduct(productId, quantity, customerId) {
  const session = await mongoose.startSession();
  session.startTransaction();

  try {
    // КРИТИЧНО: читаем stock только с primary
    const product = await ProductStock.findById(productId)
      .session(session)
      .read('primary');

    if (product.stock < quantity) {
      throw new Error('Недостаточно товара на складе');
    }

    // Атомарное уменьшение stock
    await ProductStock.updateOne(
      { _id: productId, stock: { $gte: quantity } },
      { $inc: { stock: -quantity } },
      { session }
    );

    // Создание заказа
    const order = await OrderCurrent.create([{
      customer_id: customerId,
      items: [{ product_id: productId, quantity, price: product.price }],
      status: 'pending'
    }], { session });

    await session.commitTransaction();
    return order[0];
  } catch (error) {
    await session.abortTransaction();
    throw error;
  } finally {
    session.endSession();
  }
}
```

### 5.3. Пример: чтение каталога с secondary

```javascript
async function getCatalog(category, page, limit) {
  // Безопасно читать с secondary — это просто просмотр
  return ProductCatalog.find({ category })
    .select('name price images rating')
    .skip((page - 1) * limit)
    .limit(limit)
    .read('secondaryPreferred')
    .maxTimeMS(5000);
}
```

### 5.4. Пример: статус заказа с учётом свежести

```javascript
async function getOrderStatus(orderId, customerId) {
  const order = await OrderCurrent.findOne({
    _id: orderId,
    customer_id: customerId
  });

  if (!order) {
    throw new Error('Заказ не найден');
  }

  // Если заказ создан менее 5 минут назад — читаем с primary
  const fiveMinutesAgo = new Date(Date.now() - 5 * 60 * 1000);

  if (order.created_at > fiveMinutesAgo) {
    // Свежий заказ — перечитываем с primary для актуального статуса
    return OrderCurrent.findById(orderId).read('primary');
  }

  // Старый заказ — можно вернуть данные с secondary
  return order;
}
```

---

## 6. Мониторинг replication lag

### 6.1. Проверка задержки репликации

```javascript
// Выполнить на primary
rs.status().members.forEach(member => {
  if (member.stateStr === 'SECONDARY') {
    const lag = (new Date() - member.optimeDate) / 1000;
    print(`${member.name}: lag = ${lag} seconds`);
  }
});
```

### 6.2. Алерт при превышении допустимого lag

```yaml
# Prometheus alert
- alert: ReplicationLagHigh
  expr: mongodb_replset_member_replication_lag_seconds > 5
  for: 1m
  labels:
    severity: warning
  annotations:
    summary: "Replication lag {{ $value }}s on {{ $labels.instance }}"
```

---

## 7. Итоговые рекомендации

| Правило | Описание |
|---------|----------|
| **Read-your-writes** | После записи читай с primary (корзина, свежий заказ) |
| **Inventory = Primary** | Любая проверка stock — только primary |
| **История = Secondary** | Данные старше 5 минут безопасно читать с secondary |
| **Аналитика = Secondary** | Отчёты и batch jobs — всегда secondary |
| **maxStalenessSeconds** | Всегда указывать для secondary reads |

