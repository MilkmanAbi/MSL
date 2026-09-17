// Layer 3: Qt5 shapes + text together - a filled ellipse (Qt's own path-
// fill primitive, exercising the same RENDER trapezoid path cairo's
// circle fill did in cairo-tests/01_shapes.c) and drawText at a couple
// of positions/colors, checking Qt's xcb backend against the same
// RENDER machinery GTK/cairo already validated, not just a solid rect.
#include <QApplication>
#include <QWidget>
#include <QPainter>
#include <QTimer>

class TestWidget : public QWidget {
public:
    using QWidget::QWidget;

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing, true);
        p.fillRect(rect(), Qt::white);

        p.setBrush(QColor(220, 30, 30));
        p.setPen(Qt::NoPen);
        p.drawEllipse(20, 20, 60, 60);

        p.setPen(QColor(0, 0, 0));
        QFont f = p.font();
        f.setPointSize(16);
        p.setFont(f);
        p.drawText(100, 50, "Ellipse");

        p.setPen(QColor(0, 130, 0));
        f.setBold(true);
        p.setFont(f);
        p.drawText(20, 110, "Bold Green");
    }
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    TestWidget w;
    w.resize(220, 130);
    w.show();
    QTimer::singleShot(600, &app, &QApplication::quit);
    return app.exec();
}
