import Cocoa

/// 各サービスを1〜2行で描画する。テンプレート画像なので外観と選択色はAppKitに任せる。
enum MenuBarStackedTitle {
    struct Column {
        let name: String
        let icon: NSImage?
        let rows: [String]
    }

    static func image(
        columns: [Column],
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    ) -> NSImage {
        let height: CGFloat = 22
        let gap: CGFloat = 4
        let columnGap: CGFloat = 12
        let textColor = NSColor.black
        let separator = NSAttributedString(string: "|", attributes: [
            .font: font, .foregroundColor: textColor
        ])
        let labels = columns.map { column in
            NSAttributedString(string: column.name, attributes: [
                .font: font,
                .foregroundColor: textColor
            ])
        }
        let rows = columns.map { column in
            column.rows.map { attributedRow($0, stacked: column.rows.count > 1, font: font, textColor: textColor) }
        }
        let labelWidths = columns.indices.map { columns[$0].icon == nil ? ceil(labels[$0].size().width) : 16 }
        let rowWidths = rows.map { ceil($0.map { $0.size().width }.max() ?? 0) }
        let width = columns.indices.reduce(CGFloat.zero) { $0 + labelWidths[$1] + gap + rowWidths[$1] }
            + CGFloat(max(0, columns.count - 1)) * columnGap

        // 描画ハンドラにより、Retinaでも実際の描画倍率に合わせてラスタライズする。
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for index in columns.indices {
                if let icon = columns[index].icon {
                    icon.draw(in: NSRect(x: x, y: 3, width: 16, height: 16))
                } else {
                    labels[index].draw(at: NSPoint(x: x, y: floor((height - labels[index].size().height) / 2)))
                }
                x += labelWidths[index] + gap
                let columnRows = rows[index]
                let rowHeight: CGFloat = columnRows.count > 1 ? 11 : height
                let blockHeight = CGFloat(columnRows.count) * rowHeight
                for (rowIndex, row) in columnRows.enumerated() {
                    let y = (height + blockHeight) / 2 - CGFloat(rowIndex + 1) * rowHeight
                    row.draw(at: NSPoint(x: x, y: y + floor((rowHeight - row.size().height) / 2)))
                }
                x += rowWidths[index]
                if index < columns.count - 1 {
                    separator.draw(at: NSPoint(
                        x: x + floor((columnGap - separator.size().width) / 2),
                        y: floor((height - separator.size().height) / 2)
                    ))
                    x += columnGap
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 1枠・2枠ともミディアムの太さにそろえ、文字サイズだけを変える。
    static func attributedRow(_ text: String, stacked: Bool, font: NSFont, textColor: NSColor) -> NSAttributedString {
        let row = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: stacked ? 9 : font.pointSize, weight: .medium),
            .foregroundColor: textColor
        ])
        let fullRange = NSRange(location: 0, length: row.length)
        // 区切りの点だけを透明にして、時刻の位置と従来の間隔を保つ。
        if let range = text.range(of: "%·") {
            let dotRange = text.index(after: range.lowerBound)..<range.upperBound
            row.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(dotRange, in: text))
        }
        if !stacked, let regex = try? NSRegularExpression(pattern: #"\b(?:5h|7d)\b"#) {
            for match in regex.matches(in: text, range: fullRange) {
                row.addAttributes([
                    .font: NSFont.systemFont(ofSize: max(9, font.pointSize - 2), weight: .medium),
                    .baselineOffset: 1
                ], range: match.range)
            }
        }
        return row
    }
}
