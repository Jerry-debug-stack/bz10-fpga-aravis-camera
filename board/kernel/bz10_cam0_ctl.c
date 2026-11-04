// SPDX-License-Identifier: GPL-2.0-only
/* BZ-10 CAM0 external-trigger control. The RAW10/10G data path stays in PL. */
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/bits.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

#define GPIO_DATA            0x00
#define GPIO_TRI             0x04
#define CTRL_COUNT_SHIFT     16
#define CTRL_ARM             BIT(30)
#define CTRL_START_TOGGLE    BIT(31)
#define CONTINUOUS_COUNT     0x3fffU
#define MAX_FINITE_COUNT     0x3ffeU
#define MIN_PERIOD_US        1001U
#define MAX_PERIOD_US        65535U

struct bz10_cam0_ctl {
	void __iomem *control;
	void __iomem *status;
	struct mutex lock;
	u16 period_us;
	u16 frame_count;
	bool armed;
	bool toggle;
};

static void push_control(struct bz10_cam0_ctl *cam)
{
	u32 word = cam->period_us | (cam->frame_count << CTRL_COUNT_SHIFT);

	if (cam->armed)
		word |= CTRL_ARM;
	if (cam->toggle)
		word |= CTRL_START_TOGGLE;
	writel(word, cam->control + GPIO_DATA);
}

static ssize_t period_us_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", cam->period_us);
}

static ssize_t period_us_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t len)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);
	unsigned int value;
	int ret = kstrtouint(buf, 0, &value);

	if (ret)
		return ret;
	if (value < MIN_PERIOD_US || value > MAX_PERIOD_US)
		return -ERANGE;
	mutex_lock(&cam->lock);
	if (cam->armed) {
		mutex_unlock(&cam->lock);
		return -EBUSY;
	}
	cam->period_us = value;
	push_control(cam);
	mutex_unlock(&cam->lock);
	return len;
}
static DEVICE_ATTR_RW(period_us);

static ssize_t fps_show(struct device *dev,
			struct device_attribute *attr, char *buf)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", DIV_ROUND_CLOSEST(1000000U,
							cam->period_us));
}

static ssize_t fps_store(struct device *dev,
			 struct device_attribute *attr,
			 const char *buf, size_t len)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);
	unsigned int fps, period;
	int ret = kstrtouint(buf, 0, &fps);

	if (ret)
		return ret;
	if (fps < 16 || fps > 999)
		return -ERANGE;
	period = DIV_ROUND_CLOSEST(1000000U, fps);
	if (period < MIN_PERIOD_US || period > MAX_PERIOD_US)
		return -ERANGE;
	mutex_lock(&cam->lock);
	if (cam->armed) {
		mutex_unlock(&cam->lock);
		return -EBUSY;
	}
	cam->period_us = period;
	push_control(cam);
	mutex_unlock(&cam->lock);
	return len;
}
static DEVICE_ATTR_RW(fps);

static ssize_t frames_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n",
		cam->frame_count == CONTINUOUS_COUNT ? -1 : cam->frame_count);
}

static ssize_t frames_store(struct device *dev,
			    struct device_attribute *attr,
			    const char *buf, size_t len)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);
	int value, ret = kstrtoint(buf, 0, &value);

	if (ret)
		return ret;
	if (value != -1 && (value < 1 || value > MAX_FINITE_COUNT))
		return -ERANGE;
	mutex_lock(&cam->lock);
	if (cam->armed) {
		mutex_unlock(&cam->lock);
		return -EBUSY;
	}
	cam->frame_count = value == -1 ? CONTINUOUS_COUNT : value;
	push_control(cam);
	mutex_unlock(&cam->lock);
	return len;
}
static DEVICE_ATTR_RW(frames);

static ssize_t run_show(struct device *dev,
			struct device_attribute *attr, char *buf)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", cam->armed);
}

static ssize_t run_store(struct device *dev,
			 struct device_attribute *attr,
			 const char *buf, size_t len)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);
	bool run;
	int ret = kstrtobool(buf, &run);

	if (ret)
		return ret;
	mutex_lock(&cam->lock);
	if (run) {
		/* Every start command begins a fresh trigger/parity sequence. */
		/* Hold the data bus and arm stable before the start-toggle edge. */
		cam->armed = true;
		push_control(cam);
		readl(cam->control + GPIO_DATA);
		udelay(1);
		cam->toggle = !cam->toggle;
		push_control(cam);
	} else if (!run && cam->armed) {
		cam->armed = false;
		push_control(cam);
	}
	mutex_unlock(&cam->lock);
	return len;
}
static DEVICE_ATTR_RW(run);

static ssize_t status_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct bz10_cam0_ctl *cam = dev_get_drvdata(dev);
	u32 status = readl(cam->status + GPIO_DATA);

	return sysfs_emit(buf, "0x%08x\n", status);
}
static DEVICE_ATTR_RO(status);

static struct attribute *cam0_attrs[] = {
	&dev_attr_period_us.attr,
	&dev_attr_fps.attr,
	&dev_attr_frames.attr,
	&dev_attr_run.attr,
	&dev_attr_status.attr,
	NULL,
};
ATTRIBUTE_GROUPS(cam0);

static int bz10_cam0_probe(struct platform_device *pdev)
{
	struct bz10_cam0_ctl *cam;

	cam = devm_kzalloc(&pdev->dev, sizeof(*cam), GFP_KERNEL);
	if (!cam)
		return -ENOMEM;
	cam->control = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(cam->control))
		return PTR_ERR(cam->control);
	cam->status = devm_platform_ioremap_resource(pdev, 1);
	if (IS_ERR(cam->status))
		return PTR_ERR(cam->status);
	mutex_init(&cam->lock);
	cam->period_us = 20000; /* 50 fps -> 25 Hz odd/even output */
	cam->frame_count = CONTINUOUS_COUNT;
	platform_set_drvdata(pdev, cam);
	writel(0, cam->control + GPIO_DATA);
	writel(0, cam->control + GPIO_TRI);
	push_control(cam);
	dev_info(&pdev->dev, "external trigger control ready; stopped by default\n");
	return 0;
}

static void bz10_cam0_remove(struct platform_device *pdev)
{
	struct bz10_cam0_ctl *cam = platform_get_drvdata(pdev);

	mutex_lock(&cam->lock);
	cam->armed = false;
	push_control(cam);
	mutex_unlock(&cam->lock);
}

static const struct of_device_id bz10_cam0_of_match[] = {
	{ .compatible = "local,bz10-cam0-raw10g-trigger-v1" },
	{ }
};
MODULE_DEVICE_TABLE(of, bz10_cam0_of_match);

static struct platform_driver bz10_cam0_driver = {
	.probe = bz10_cam0_probe,
	.remove = bz10_cam0_remove,
	.driver = {
		.name = "bz10-cam0-raw10g-ctl",
		.of_match_table = bz10_cam0_of_match,
		.dev_groups = cam0_groups,
	},
};
module_platform_driver(bz10_cam0_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("BZ-10 CAM0 RAW10/10G PL external-trigger control");
