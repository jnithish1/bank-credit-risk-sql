# Raw data

The full dataset (~70 MB, 8 CSV files) is not committed. To get it:

1. Download the **Berka / PKDD'99 Financial** dataset in CSV form (for example,
   search Kaggle for "Berka dataset"). The original is documented at the
   [CTU Relational Dataset Repository](https://relational.fel.cvut.cz/dataset/Financial).
2. Put these files in this folder:
   `account.csv  card.csv  client.csv  disp.csv  district.csv  loan.csv  order.csv  trans.csv`
3. Run `make pipeline`.

No download? `make sample` builds everything from the 10% sample in `data/sample/`.
