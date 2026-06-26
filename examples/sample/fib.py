def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


def main():
    total = 0
    for i in range(10):
        total = total + fib(i)
    print("sum of the first 10 Fibonacci numbers:", total)


if __name__ == "__main__":
    main()
