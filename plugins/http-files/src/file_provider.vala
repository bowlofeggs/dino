using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Plugins.HttpFiles {

public class FileProvider : Dino.FileProvider, Object {

    private StreamInteractor stream_interactor;
    private Dino.Database dino_db;
    private Regex url_regex = /^(?i)\b((?:[a-z][\w-]+:(?:\/{1,3}|[a-z0-9%])|www\d{0,3}[.]|[a-z0-9.\-]+[.][a-z]{2,4}\/)(?:[^\s()<>]+|\(([^\s()<>]+|(\([^\s()<>]+\)))*\))+(?:\(([^\s()<>]+|(\([^\s()<>]+\)))*\)|[^\s`!()\[\]{};:'".,<>?«»“”‘’]))$/;
    private Regex omemo_url_regex = /^aesgcm:\/\/(.*)#(([A-Fa-f0-9]{2}){48}|([A-Fa-f0-9]{2}){44})$/;

    public FileProvider(StreamInteractor stream_interactor, Dino.Database dino_db) {
        this.stream_interactor = stream_interactor;
        this.dino_db = dino_db;

        stream_interactor.get_module(MessageProcessor.IDENTITY).received_pipeline.connect(new ReceivedMessageListener(this));
    }

    private class ReceivedMessageListener : MessageListener {

        public string[] after_actions_const = new string[]{ "STORE" };
        public override string action_group { get { return ""; } }
        public override string[] after_actions { get { return after_actions_const; } }

        private FileProvider outer;
        private StreamInteractor stream_interactor;

        public ReceivedMessageListener(FileProvider outer) {
            this.outer = outer;
            this.stream_interactor = outer.stream_interactor;
        }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            if (outer.url_regex.match(message.body)) {
                string? oob_url = Xmpp.Xep.OutOfBandData.get_url_from_message(stanza);

                bool normal_file = oob_url != null && oob_url == message.body;
                bool omemo_file = outer.omemo_url_regex.match(message.body);

                if (normal_file || omemo_file) {
                    yield outer.on_file_message(message, conversation);
                }
            }
            return false;
        }
    }

    private async void on_file_message(Entities.Message message, Conversation conversation) {
        // Hide message
        ContentItem? content_item = stream_interactor.get_module(ContentItemStore.IDENTITY).get_item(conversation, 1, message.id);
        if (content_item != null) {
            stream_interactor.get_module(ContentItemStore.IDENTITY).set_item_hide(content_item, true);
        }

        var additional_info = message.id.to_string();

        var receive_data = new HttpFileReceiveData();
        receive_data.url = message.body;

        var file_meta = new HttpFileMeta();
        file_meta.file_name = message.body.substring(message.body.last_index_of("/") + 1);
        file_meta.message = message;

        file_incoming(additional_info, message.from, message.time, message.local_time, conversation, receive_data, file_meta);
    }

    public async FileMeta get_meta_info(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws FileReceiveError {
        HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
        if (http_receive_data == null) return file_meta;

        var session = new Soup.Session();
        var head_message = new Soup.Message("HEAD", http_receive_data.url);

        if (head_message != null) {
            try {
                yield session.send_async(head_message, null);
            } catch (Error e) {
                throw new FileReceiveError.GET_METADATA_FAILED("HEAD request failed");
            }

            string? content_type = null, content_length = null;
            head_message.response_headers.foreach((name, val) => {
                if (name == "Content-Type") content_type = val;
                if (name == "Content-Length") content_length = val;
            });
            file_meta.mime_type = content_type;
            if (content_length != null) {
                file_meta.size = int.parse(content_length);
            }
        }

        return file_meta;
    }

    public async InputStream download(FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) throws FileReceiveError {
        HttpFileReceiveData? http_receive_data = receive_data as HttpFileReceiveData;
        if (http_receive_data == null) assert(false);

        try {
            var session = new Soup.Session();
            Soup.Request request = session.request(http_receive_data.url);

            return yield request.send_async(null);
        } catch (Error e) {
            throw new FileReceiveError.DOWNLOAD_FAILED("Downloading file error: %s".printf(e.message));
        }
    }

    public FileMeta get_file_meta(FileTransfer file_transfer) throws FileReceiveError {
        Conversation? conversation = stream_interactor.get_module(ConversationManager.IDENTITY).get_conversation(file_transfer.counterpart.bare_jid, file_transfer.account);
        if (conversation == null) throw new FileReceiveError.GET_METADATA_FAILED("No conversation");

        Message? message = stream_interactor.get_module(MessageStorage.IDENTITY).get_message_by_id(int.parse(file_transfer.info), conversation);
        if (message == null) throw new FileReceiveError.GET_METADATA_FAILED("No message");

        var file_meta = new HttpFileMeta();
        file_meta.size = file_transfer.size;
        file_meta.mime_type = file_transfer.mime_type;

        // Extract file name from URL
        file_meta.file_name = Uri.unescape_string(message.body);
        file_meta.file_name = file_meta.file_name.substring(file_meta.file_name.last_index_of("/") + 1);
        if (file_meta.file_name.contains("#")) {
            file_meta.file_name = file_meta.file_name.substring(0, file_meta.file_name.last_index_of("#"));
        }
        
        file_meta.message = message;

        return file_meta;
    }

    public FileReceiveData? get_file_receive_data(FileTransfer file_transfer) {
        Conversation? conversation = stream_interactor.get_module(ConversationManager.IDENTITY).get_conversation(file_transfer.counterpart.bare_jid, file_transfer.account);
        if (conversation == null) return null;

        Message? message = stream_interactor.get_module(MessageStorage.IDENTITY).get_message_by_id(int.parse(file_transfer.info), conversation);
        if (message == null) return null;

        var receive_data = new HttpFileReceiveData();
        receive_data.url = message.body;

        return receive_data;
    }

    public int get_id() { return 0; }
}

}
