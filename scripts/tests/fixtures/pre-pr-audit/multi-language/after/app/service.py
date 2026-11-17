def total(items, discount=0):
    return sum(i["price"] for i in items) - discount
