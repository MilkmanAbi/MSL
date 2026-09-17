// Layer 3: minimal Qt5 - a bare QWidget overriding paintEvent with
// QPainter (filled rect + text), no signals/slots/Q_OBJECT (so this
// compiles with plain g++, no Qt MOC step needed). Qt's xcb platform
// plugin is a genuinely different X11 rendering path than GTK/GDK - this
// isolates "does Qt's own X11 backend work at all through mslgd" the
// same way 01_window.c did for GTK.
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
        p.fillRect(rect(), Qt::white);
        p.setBrush(QColor(0, 100, 255));
        p.setPen(Qt::NoPen);
        p.drawRect(15, 15, width() - 30, height() - 30);
        p.setPen(Qt::white);
        QFont f = p.font();
        f.setBold(true);
        f.setPointSize(20);
        p.setFont(f);
        p.drawText(rect(), Qt::AlignCenter, "Qt5");
    }
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    TestWidget w;
    w.resize(200, 100);
    w.show();
    QTimer::singleShot(600, &app, &QApplication::quit);
    return app.exec();
}
