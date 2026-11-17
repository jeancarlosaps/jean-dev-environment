from app.service import total


def test_total_with_discount():
    assert total([{"price": 10}], discount=2) == 8
