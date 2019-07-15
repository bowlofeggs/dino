using Gee;
using Gdk;
using Gtk;
using Pango;
using Xmpp;
using Unicode;

using Dino.Entities;

namespace Dino.Ui.ConversationSummary {

public class ContentItemWidgetFactory : Object {

    private StreamInteractor stream_interactor;
    private HashMap<string, WidgetGenerator> generators = new HashMap<string, WidgetGenerator>();

    public ContentItemWidgetFactory(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        generators[MessageItem.TYPE] = new MessageItemWidgetGenerator(stream_interactor);
        generators[FileItem.TYPE] = new FileItemWidgetGenerator(stream_interactor);
    }

    public Widget? get_widget(ContentItem item) {
        WidgetGenerator? generator = generators[item.type_];
        if (generator != null) {
            return (Widget?) generator.get_widget(item);
        }
        return null;
    }

    public void register_widget_generator(WidgetGenerator generator) {
        generators[generator.handles_type] = generator;
    }
}

public interface WidgetGenerator : Object {
    public abstract string handles_type { get; set; }
    public abstract Object get_widget(ContentItem item);
}

public class MessageItemWidgetGenerator : WidgetGenerator, Object {

    public string handles_type { get; set; default=FileItem.TYPE; }

    private StreamInteractor stream_interactor;

    public MessageItemWidgetGenerator(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
    }

    public Object get_widget(ContentItem item) {
        MessageItem message_item = item as MessageItem;
        Conversation conversation = message_item.conversation;
        Message message = message_item.message;

        Label label = new Label("") { use_markup=true, xalign=0, selectable=true, wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR, vexpand=true, visible=true };
        string markup_text = message.body;
        if (markup_text.length > 10000) {
            markup_text = markup_text.substring(0, 10000) + " [" + _("Message too long") + "]";
        }
        if (message_item.message.body.has_prefix("/me")) {
            markup_text = markup_text.substring(3);
        }

        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            markup_text = Util.parse_add_markup(markup_text, conversation.nickname, true, true);
        } else {
            markup_text = Util.parse_add_markup(markup_text, null, true, true);
        }

        if (message_item.message.body.has_prefix("/me")) {
            string display_name = Util.get_message_display_name(stream_interactor, message, conversation.account);
            update_me_style(stream_interactor, message.real_jid ?? message.from, display_name, conversation.account, label, markup_text);
            label.realize.connect(() => update_me_style(stream_interactor, message.real_jid ?? message.from, display_name, conversation.account, label, markup_text));
            label.style_updated.connect(() => update_me_style(stream_interactor, message.real_jid ?? message.from, display_name, conversation.account, label, markup_text));
        }

        int only_emoji_count = Util.get_only_emoji_count(markup_text);
        if (only_emoji_count != -1) {
            string size_str = only_emoji_count < 5 ? "xx-large" : "large";
            markup_text = @"<span size=\'$size_str\'>" + markup_text + "</span>";
        }

        label.label = markup_text;

        Box box = new Box(Orientation.VERTICAL, 3) { visible=true };
        box.add(label);
        box.add(new ReactionsWidget(conversation.account, message, stream_interactor) { visible=true });

        return box;
    }

    public static void update_me_style(StreamInteractor stream_interactor, Jid jid, string display_name, Account account, Label label, string action_text) {
        string color = Util.get_name_hex_color(stream_interactor, account, jid, Util.is_dark_theme(label));
        label.label = @"<span color=\"#$(color)\">$(Markup.escape_text(display_name))</span>" + action_text;
    }
}

public class FileItemWidgetGenerator : WidgetGenerator, Object {

    public StreamInteractor stream_interactor;
    public string handles_type { get; set; default=FileItem.TYPE; }

    private const int MAX_HEIGHT = 300;
    private const int MAX_WIDTH = 600;

    public FileItemWidgetGenerator(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
    }

    public Object get_widget(ContentItem item) {
        FileItem file_item = item as FileItem;
        FileTransfer transfer = file_item.file_transfer;

        if (transfer.mime_type != null) {
            foreach (PixbufFormat pixbuf_format in Pixbuf.get_formats()) {
                foreach (string mime_type in pixbuf_format.get_mime_types()) {
                    if (mime_type == transfer.mime_type)
                        return getImageWidget(transfer);
                    }
            }
        }

        return getDefaultWidget(transfer);
    }

    private Widget getImageWidget(FileTransfer file_transfer) {
        Image image = new Image() { halign=Align.START, visible = true };
        Gdk.Pixbuf pixbuf;
        try {
            pixbuf = new Gdk.Pixbuf.from_file(file_transfer.get_file().get_path());
        } catch (Error error) {
            return null;
        }

        pixbuf = pixbuf.apply_embedded_orientation();

        int max_scaled_height = MAX_HEIGHT * image.scale_factor;
        if (pixbuf.height > max_scaled_height) {
            pixbuf = pixbuf.scale_simple((int) ((double) max_scaled_height / pixbuf.height * pixbuf.width), max_scaled_height, Gdk.InterpType.BILINEAR);
        }
        int max_scaled_width = MAX_WIDTH * image.scale_factor;
        if (pixbuf.width > max_scaled_width) {
            pixbuf = pixbuf.scale_simple(max_scaled_width, (int) ((double) max_scaled_width / pixbuf.width * pixbuf.height), Gdk.InterpType.BILINEAR);
        }
        pixbuf = crop_corners(pixbuf, 3 * image.get_scale_factor());
        Util.image_set_from_scaled_pixbuf(image, pixbuf);
        Util.force_css(image, "* { box-shadow: 0px 0px 2px 0px rgba(0,0,0,0.1); margin: 2px; border-radius: 3px; }");

        Builder builder = new Builder.from_resource("/im/dino/Dino/conversation_summary/image_toolbar.ui");
        Widget toolbar = builder.get_object("main") as Widget;
        Util.force_background(toolbar, "rgba(0, 0, 0, 0.5)");
        Util.force_css(toolbar, "* { padding: 3px; border-radius: 3px; }");

        Label url_label = builder.get_object("url_label") as Label;
        Util.force_color(url_label, "#eee");

        if (file_transfer.file_name != null && file_transfer.file_name != "") {
            string caption = file_transfer.file_name;
            url_label.label = caption;
        } else {
            url_label.visible = false;
        }

        Image open_image = builder.get_object("open_image") as Image;
        Util.force_css(open_image, "*:not(:hover) { color: #eee; }");
        Button open_button = builder.get_object("open_button") as Button;
        Util.force_css(open_button, "*:hover { background-color: rgba(255,255,255,0.3); border-color: transparent; }");
        open_button.clicked.connect(() => {
            try{
                AppInfo.launch_default_for_uri(file_transfer.get_file().get_uri(), null);
            } catch (Error err) {
                info("Could not to open file://%s: %s", file_transfer.get_file().get_path(), err.message);
            }
        });

        Revealer toolbar_revealer = new Revealer() { transition_type=RevealerTransitionType.CROSSFADE, transition_duration=400, visible=true };
        toolbar_revealer.add(toolbar);

        Grid grid = new Grid() { visible=true };
        grid.attach(toolbar_revealer, 0, 0, 1, 1);
        grid.attach(image, 0, 0, 1, 1);

        EventBox event_box = new EventBox() { halign=Align.START, visible=true };
        event_box.events = EventMask.POINTER_MOTION_MASK;
        event_box.add(grid);
        event_box.enter_notify_event.connect(() => { toolbar_revealer.reveal_child = true; return false; });
        event_box.leave_notify_event.connect(() => { toolbar_revealer.reveal_child = false; return false; });

        return event_box;
    }

    private static Gdk.Pixbuf crop_corners(Gdk.Pixbuf pixbuf, double radius = 3) {
        Cairo.Context ctx = new Cairo.Context(new Cairo.ImageSurface(Cairo.Format.ARGB32, pixbuf.width, pixbuf.height));
        Gdk.cairo_set_source_pixbuf(ctx, pixbuf, 0, 0);
        double degrees = Math.PI / 180.0;
        ctx.new_sub_path();
        ctx.arc(pixbuf.width - radius, radius, radius, -90 * degrees, 0 * degrees);
        ctx.arc(pixbuf.width - radius, pixbuf.height - radius, radius, 0 * degrees, 90 * degrees);
        ctx.arc(radius, pixbuf.height - radius, radius, 90 * degrees, 180 * degrees);
        ctx.arc(radius, radius, radius, 180 * degrees, 270 * degrees);
        ctx.close_path();
        ctx.clip();
        ctx.paint();
        return Gdk.pixbuf_get_from_surface(ctx.get_target(), 0, 0, pixbuf.width, pixbuf.height);
    }

    private Widget getDefaultWidget(FileTransfer file_transfer) {
        Box main_box = new Box(Orientation.HORIZONTAL, 4) { halign=Align.START, visible=true };
        string? icon_name = file_transfer.mime_type != null ? ContentType.get_generic_icon_name(file_transfer.mime_type) : null;
        Image content_type_image = new Image.from_icon_name(icon_name, IconSize.DND) { visible=true };
        main_box.add(content_type_image);

        Box right_box = new Box(Orientation.VERTICAL, 0) { visible=true };
        Label name_label = new Label(file_transfer.file_name) { ellipsize=EllipsizeMode.END, xalign=0, yalign=0, visible=true};
        right_box.add(name_label);
        Label mime_label = new Label("<span size='small'>" + _("File") + ": " + file_transfer.mime_type + "</span>") { use_markup=true, xalign=0, yalign=1, visible=true};
        mime_label.get_style_context().add_class("dim-label");
        right_box.add(mime_label);
        main_box.add(right_box);

        EventBox event_box = new EventBox() { halign=Align.START, visible=true };
        event_box.add(main_box);

        event_box.enter_notify_event.connect((event) => {
            event.get_window().set_cursor(new Cursor.for_display(Gdk.Display.get_default(), CursorType.HAND2));
            return false;
        });
        event_box.leave_notify_event.connect((event) => {
            event.get_window().set_cursor(new Cursor.for_display(Gdk.Display.get_default(), CursorType.XTERM));
            return false;
        });
        event_box.button_release_event.connect((event_button) => {
            if (event_button.button == 1) {
                try{
                    AppInfo.launch_default_for_uri(file_transfer.get_file().get_uri(), null);
                } catch (Error err) {
                    print("Tried to open " + file_transfer.get_file().get_path());
                }
            }
            return false;
        });

        return event_box;
    }
}

public class ReactionsWidget : Box {

    private Account account;
    private Message message;
    private StreamInteractor stream_interactor;

    private HashMap<string, Label> reaction_counts = new HashMap<string, Label>();
    private HashMap<string, Widget> reaction_widgets = new HashMap<string, Widget>();
    private HashMap<string, Gee.List<Jid>> reactions = new HashMap<string, Gee.List<Jid>>();

    private Box reactions_box = new Box(Orientation.HORIZONTAL, 5) { visible=true };
    private bool initialized = false;

    public ReactionsWidget(Account account, Message message, StreamInteractor stream_interactor) {
        this.account = account;
        this.message = message;
        this.stream_interactor = stream_interactor;

        this.add(reactions_box);

        HashMap<string, Gee.List<Jid>> reactions = stream_interactor.get_module(Reactions.IDENTITY).get_message_reactions(account, message);
        if (reactions.size > 0) {
            initialize();
        }
        foreach (string reaction in reactions.keys) {
            foreach (Jid jid in reactions[reaction]) {
                reaction_added(reaction, jid);
            }
        }

        stream_interactor.get_module(Reactions.IDENTITY).reaction_added.connect((account, message, jid, reaction) => {
            if (account.equals(this.account) && message.equals(this.message)) {
                reaction_added(reaction, jid);
            }
        });
        stream_interactor.get_module(Reactions.IDENTITY).reaction_removed.connect((account, message, jid, reaction) => {
            if (account.equals(this.account) && message.equals(this.message)) {
                reaction_removed(reaction, jid);
            }
        });
    }

    public void initialize() {
        MenuButton add_button = new MenuButton() { visible=true };
        add_button.get_style_context().add_class("reaction-box");
        Image add_image = new Image.from_icon_name("dino-emoticon-add-symbolic", IconSize.SMALL_TOOLBAR) { margin_left=5, margin_right=5, visible=true };
        add_button.add(add_image);
        reactions_box.pack_end(add_button);

        EmojiChooser chooser = new EmojiChooser();
        chooser.emoji_picked.connect((emoji) => {
            stream_interactor.get_module(Reactions.IDENTITY).add_reaction(account, message, emoji);
        });
        add_button.set_popover(chooser);

        initialized = true;
    }

    public void reaction_added(string reaction, Jid jid) {
        if (!initialized) {
            initialize();
        }

        if (reactions.contains(reaction)) {
            reactions[reaction].add(jid);
            reaction_counts[reaction].label = "<span size='small'>" + reactions[reaction].size.to_string() + "</span>";
            if (jid.equals(account.bare_jid)) {
                reaction_widgets[reaction].get_style_context().add_class("own-reaction");
            }
        } else {
            reactions[reaction] = new ArrayList<Jid>(Jid.equals_func);
            reactions[reaction].add(jid);

            Label reaction_label = new Label("<span size='small'>" + reaction + "</span>") { use_markup=true, visible=true };
            Label count_label = new Label("<span size='small'>" + reactions[reaction].size.to_string() + "</span>") { use_markup=true, visible=true };

            Button button = new Button() { visible=true };
            button.get_style_context().add_class("reaction-box");
            Box reaction_box = new Box(Orientation.HORIZONTAL, 4) { visible=true };
            if (jid.equals(account.bare_jid)) {
                button.get_style_context().add_class("own-reaction");
            }
            reaction_box.add(reaction_label);
            reaction_box.add(count_label);

            button.add(reaction_box);
            reactions_box.add(button);

            button.clicked.connect(() => {
                if (reactions[reaction].contains(account.bare_jid)) {
                    stream_interactor.get_module(Reactions.IDENTITY).remove_reaction(account, message, reaction);
                } else {
                    stream_interactor.get_module(Reactions.IDENTITY).add_reaction(account, message, reaction);
                }
            });

            reaction_counts[reaction] = count_label;
            reaction_widgets[reaction] = button;
        }

        foreach (Jid a in reactions[reaction]) {
            print(a.to_string() + " ");
        }
        print("\n");
    }

    public void reaction_removed(string reaction, Jid jid) {
        if (!reactions.contains(reaction)) warning("wtf");

        reactions[reaction].remove(jid);
        if (reactions[reaction].size > 0) {
            reaction_counts[reaction].label = "<span size='small'>" + reactions[reaction].size.to_string() + "</span>";
            if (jid.equals(account.bare_jid)) {
                reaction_widgets[reaction].get_style_context().remove_class("own-reaction");
            }
        } else {
            reaction_widgets[reaction].destroy();
        }
    }
}

}
