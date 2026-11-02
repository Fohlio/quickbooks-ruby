describe Quickbooks::Util::XmlMapping do
  module XmlMappingSpec
    class Child
      include Quickbooks::Util::XmlMapping
      xml_name 'Child'
      xml_accessor :kind, :from => '@kind'
      xml_accessor :value, :from => :content
    end

    class Parent
      include Quickbooks::Util::XmlMapping
      xml_convention :camelcase
      xml_name 'Parent'
      xml_accessor :id, :from => 'Id', :as => Integer
      xml_accessor :display_name
      xml_accessor :active?
      xml_accessor :amount, :from => 'Amt', :as => BigDecimal, :to_xml => Proc.new { |v| v && v.to_f }
      xml_accessor :txn_date, :from => 'TxnDate', :as => Date
      xml_accessor :child, :from => 'Child', :as => Child
      xml_accessor :children, :from => 'Item', :as => [Child], :in => 'Items'
      xml_accessor :tags, :from => 'Tag', :as => []
      xml_reader :pairs, :from => 'Pairs/Pair', :as => { :key => 'K', :value => 'V' }
    end
  end

  let(:xml) { <<-XML }
    <Parent xmlns="http://schema.intuit.com/finance/v3">
      <Id>42</Id>
      <DisplayName>Acme</DisplayName>
      <Active>true</Active>
      <Amt>10.50</Amt>
      <TxnDate>2026-01-02</TxnDate>
      <Child kind="a">first</Child>
      <Items><Item kind="b">x</Item><Item kind="c">y</Item></Items>
      <Tag>one</Tag><Tag>two</Tag>
      <Pairs><Pair><K>a</K><V>1</V></Pair><Pair><K>b</K><V>2</V></Pair></Pairs>
    </Parent>
  XML

  let(:parsed) { XmlMappingSpec::Parent.from_xml(xml) }

  it "parses elements, attributes, content, casts and collections" do
    expect(parsed.id).to eq(42)
    expect(parsed.display_name).to eq("Acme")
    expect(parsed.active?).to be true
    expect(parsed.amount).to eq(BigDecimal("10.5"))
    expect(parsed.txn_date).to eq(Date.new(2026, 1, 2))
    expect(parsed.child.kind).to eq("a")
    expect(parsed.child.value).to eq("first")
    expect(parsed.children.map(&:value)).to eq(%w(x y))
    expect(parsed.tags).to eq(%w(one two))
    expect(parsed.pairs).to eq("a" => "1", "b" => "2")
  end

  it "accepts Nokogiri nodes and documents" do
    doc = Nokogiri::XML(xml)
    expect(XmlMappingSpec::Parent.from_xml(doc).id).to eq(42)
    expect(XmlMappingSpec::Parent.from_xml(doc.root).id).to eq(42)
  end

  it "defaults missing values" do
    empty = XmlMappingSpec::Parent.from_xml("<Parent><Id></Id></Parent>")
    expect(empty.id).to be_nil
    expect(empty.child).to be_nil
    expect(empty.children).to eq([])
    expect(empty.pairs).to eq({})
    expect(XmlMappingSpec::Parent.new.tags).to eq([])
  end

  it "serializes back to XML" do
    node = parsed.to_xml
    expect(node.name).to eq("Parent")
    expect(node.at("Id").content).to eq("42")
    expect(node.at("Amt").content).to eq("10.5")
    expect(node.at("Child")["kind"]).to eq("a")
    expect(node.xpath("Items/Item").map(&:content)).to eq(%w(x y))
    expect(node.xpath("Tag").map(&:content)).to eq(%w(one two))
    expect(node.xpath("Pairs/Pair/K").map(&:content)).to eq(%w(a b))
  end

  it "omits nil values and empty collections, but keeps :in wrappers (as ROXML did)" do
    node = XmlMappingSpec::Parent.new.tap { |p| p.display_name = "Acme" }.to_xml
    expect(node.elements.map(&:name)).to eq(%w(DisplayName Items))
  end

  it "rejects duplicate accessors" do
    expect {
      XmlMappingSpec::Parent.class_eval { xml_accessor :id }
    }.to raise_error(/already defined/)
  end
end
